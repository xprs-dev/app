/*
 * Composing the packets a group signs (docs/XPRS.md section 26).
 *
 * Pure builders: they take the group's private scalar and hand back a signed
 * packet. Nothing here airs anything or touches a store, so the composition
 * rules -- which are protocol -- can be tested without a node.
 *
 * The signing key is the GROUP's, never the operator's. `publishWire` signs
 * with the profile key only when `f:` is our own callsign, so an admin act
 * (`f:` is the group) has to arrive already signed and be aired verbatim.
 */
import 'xprs_packet.dart';
import 'xprs_sig.dart';
import 'xprs_vocab.dart';

class XprsGroupAct {
  /// A group announcing itself (26.1).
  ///
  /// "A group needs no announcement packet of its own, no registry and no
  /// creation ceremony" -- this is the ordinary `t:identity` of section 9.3,
  /// self-signed, which is what proves possession of the group's private key.
  /// `nick:` is shown only when that signature verifies (9.3.1).
  static XprsPacket? identity({
    required String group,
    required String npub,
    required BigInt scalar,
    String nick = '',
    int? nowMs,
  }) {
    final g = group.trim().toUpperCase();
    if (g.isEmpty || !npub.startsWith('npub1')) return null;
    final n = _nick(nick);
    final p = XprsPacket.parse('t:identity f:$g ts:${xprsNowTs(nowMs)} '
        'k:$npub${n.isEmpty ? '' : ' nick:$n'}');
    if (p == null) return null;
    return xprsSign(p, scalar);
  }

  /// `grant:` -- admit members, appoint a moderator, or list a subgroup.
  ///
  /// One packet takes a LIST, "so admitting a dozen people is one packet rather
  /// than a dozen" (26.3). `role:mod` makes a moderator, `role:sub` lists a
  /// subgroup (26.2), and neither makes the ordinary case cost anything.
  ///
  /// Only the admin may appoint, so this is always signed as the group.
  static XprsPacket? grant({
    required String group,
    required List<String> callsigns,
    required BigInt scalar,
    String role = '',
    String? until,
    int? nowMs,
  }) =>
      _act(
        group: group,
        signer: group,
        scalar: scalar,
        verb: 'grant',
        callsigns: callsigns,
        role: role,
        until: until,
        nowMs: nowMs,
      );

  /// `revoke:` -- remove somebody, or suspend them with `until:`.
  ///
  /// "A suspension is a revocation with an end." `since:` is the admin voiding
  /// a moderator's whole record from that moment (26.4), which is why it costs
  /// one packet rather than one per act to undo a compromised key.
  ///
  /// [signer] may be a moderator: their act "looks the same but is signed by
  /// them", and the scalar passed must match.
  static XprsPacket? revoke({
    required String group,
    required List<String> callsigns,
    required BigInt scalar,
    String? signer,
    String? until,
    String? since,
    int? nowMs,
  }) =>
      _act(
        group: group,
        signer: signer ?? group,
        scalar: scalar,
        verb: 'revoke',
        callsigns: callsigns,
        until: until,
        since: since,
        nowMs: nowMs,
      );

  /// The member consenting (26.3.1), signed by THEM.
  ///
  /// `r:` names the grant being accepted, so the acceptance is evidence of a
  /// specific offer rather than a floating assertion -- and a grant that was
  /// withdrawn cannot be accepted after the fact.
  static XprsPacket? accept({
    required String group,
    required String member,
    required String grantId,
    required BigInt scalar,
    String role = 'member',
    int? nowMs,
  }) {
    final g = group.trim().toUpperCase();
    final m = member.trim().toUpperCase();
    final r = grantId.trim();
    if (g.isEmpty || m.isEmpty || r.isEmpty) return null;
    final word = role.trim().toLowerCase() == 'mod' ? 'mod' : 'member';
    final p = XprsPacket.parse(
        't:moderate f:$m d:$g ts:${xprsNowTs(nowMs)} r:$r accept:$word');
    if (p == null) return null;
    return xprsSign(p, scalar);
  }

  /// The member going (26.3.1), signed by them. No `r:` -- leaving is theirs
  /// alone and needs nobody's agreement. What it leaves behind is a signed
  /// record that they went, rather than a silence somebody could explain any
  /// way they liked.
  static XprsPacket? leave({
    required String group,
    required String member,
    required BigInt scalar,
    int? nowMs,
  }) {
    final g = group.trim().toUpperCase();
    final m = member.trim().toUpperCase();
    if (g.isEmpty || m.isEmpty) return null;
    final p = XprsPacket.parse(
        't:moderate f:$m d:$g ts:${xprsNowTs(nowMs)} leave:group');
    if (p == null) return null;
    return xprsSign(p, scalar);
  }

  /// `r:<id> hide:message` -- "asks clients not to display the packet named in
  /// `r:`; it cannot unsend anything, because nothing on a radio can" (26.3).
  /// A moderator may do this, so [signer] and [scalar] may be theirs.
  static XprsPacket? hide({
    required String group,
    required String messageId,
    required BigInt scalar,
    String? signer,
    int? nowMs,
  }) {
    final g = group.trim().toUpperCase();
    final id = messageId.trim();
    if (g.isEmpty || id.isEmpty) return null;
    final p = XprsPacket.parse('t:moderate f:${(signer ?? g).trim().toUpperCase()} '
        'd:$g ts:${xprsNowTs(nowMs)} r:$id hide:message');
    if (p == null) return null;
    return xprsSign(p, scalar);
  }

  static XprsPacket? _act({
    required String group,
    required String signer,
    required BigInt scalar,
    required String verb,
    required List<String> callsigns,
    String role = '',
    String? until,
    String? since,
    int? nowMs,
  }) {
    final g = group.trim().toUpperCase();
    final calls = callsigns
        .map((c) => c.trim().toUpperCase())
        .where((c) => c.isNotEmpty)
        .toSet()
        .toList();
    if (g.isEmpty || calls.isEmpty) return null;

    final b = StringBuffer('t:moderate f:${signer.trim().toUpperCase()} '
        'd:$g ts:${xprsNowTs(nowMs)} $verb:${calls.join(',')}');
    if (role.isNotEmpty) b.write(' role:$role');
    if (until != null && until.isNotEmpty) b.write(' until:$until');
    if (since != null && since.isNotEmpty) b.write(' since:$since');

    final p = XprsPacket.parse(b.toString());
    // A roster act that does not fit is not sent short: the callsign list is
    // the payload, and a truncated list is a different act. The caller splits.
    if (p == null || !p.fits) return null;
    return xprsSign(p, scalar);
  }

  /// `nick:` is a `word` (section 4.3): no spaces, and short enough to leave
  /// room for the signature.
  static String _nick(String v) {
    final s = v.trim().replaceAll(RegExp(r'\s+'), '-');
    return s.length > 24 ? s.substring(0, 24) : s;
  }
}
