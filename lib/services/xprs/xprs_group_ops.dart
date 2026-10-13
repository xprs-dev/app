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

import '../../util/media_ref.dart';
import '../../util/nostr_crypto.dart';
import '../media/media_fetch.dart';
import '../media/media_preview.dart';
import '../reticulum/rns_service.dart';
import 'xprs_archive.dart';
import 'xprs_group_act.dart';
import 'xprs_group_keys.dart';
import 'xprs_groups.dart';
import 'xprs_id.dart';
import 'xprs_packet.dart';
import 'xprs_profiles.dart';
import 'xprs_publisher.dart';
import 'xprs_sig.dart';
import 'xprs_vocab.dart';

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
    // 26.7: membership decides what a co-member's client SHOWS, and it shows
    // only the roster. But 26.1 makes the group its own admin — the person who
    // holds the key is never named in `roles` — so an admin who never joins
    // their own group is a stranger to every other member's display, and their
    // posts get filtered out on the far side. The roster is meant to publish
    // "everyone who belongs, including members who never speak" (26.7), so the
    // admin records themselves as one: a self-grant, then the self-acceptance
    // 26.3.1 requires (a grant confers nothing until the person signs for it).
    // Both go through the same grant/accept doors a person taps, and both are
    // one-time acts at creation.
    final me = XprsArchive.instance.selfCallsign.trim().toUpperCase();
    if (me.isNotEmpty) {
      final gr = grant(g.callsign, [me], role: 'member');
      final wire = gr.wire;
      if (gr.ok && wire != null) {
        final gid = xprsIdentifierOf(wire);
        if (gid != null) accept(g.callsign, me, gid, role: 'member');
      }
    }
    return (callsign: g.callsign, npub: g.npub, nick: g.nick);
  }

  /// A folder inside [parent]: a subgroup (10.2). "A subgroup is not a new
  /// kind of thing": its own key, its own `X5` callsign, its own roster, and
  /// a `grant:<X5> role:sub` signed by the parent that lists it. Only the
  /// parent's admin can sign that, and the admin keeps the folder's key too,
  /// which is 10.2's "ordinary case": authority over a subgroup is holding
  /// its key, never a walk up the tree.
  ///
  /// Null when we do not administer [parent], when the parent already sits
  /// at the fifth level (10.2: a deeper listing is ignored by every client,
  /// so minting one would make a folder nobody can see), or when nothing
  /// could be minted. Membership does not travel down: who is offered a
  /// place in the folder is the caller's to say, with [grant].
  static ({String callsign, String npub, String nick})? createFolder(
      String parent,
      {String nick = ''}) {
    final p = parent.trim().replaceFirst('#', '').toUpperCase();
    if (!XprsGroupKeys.instance.holdsKey(p)) return null;
    if (XprsGroups.depthIn(XprsGroups.instance.parents(), p) >=
        XprsGroups.maxDepth) {
      return null;
    }
    final g = create(nick: nick);
    if (g == null) return null;
    final listed = grant(p, [g.callsign], role: 'sub');
    if (!listed.ok) {
      // A folder no parent lists is a stray group under a name nobody chose.
      forget(g.callsign);
      return null;
    }
    return g;
  }

  /// A group's picture (6.3.2 applied to the group's own `t:identity`, 10.1:
  /// "a group is a station"). [token] is `file:<sha>.<ext>` of a thumbnail
  /// already in the media archive, or empty to take the picture back with
  /// `file:-`. Signed with the group's key, so only the admin can say it.
  ///
  /// The name goes out with it every time: a decoration states every field
  /// it has (6.3.2), so a picture announced without the name would read as
  /// the name being cleared.
  static XprsGroupOpResult setPicture(String group, String token) {
    final g = group.trim().replaceFirst('#', '').toUpperCase();
    final scalar = XprsGroupKeys.instance.scalarFor(g);
    if (scalar == null) {
      return XprsGroupOpResult.failed('only the admin of $g can do that');
    }
    final t = token.trim();
    if (t.isNotEmpty) {
      final ref = MediaRef.parse(t);
      final meta = ref == null
          ? null
          : MediaFetch.instance.archive?.call()?.getMeta(ref.sha256);
      // performance.md 8.17: a picture is at most 8 KiB, so the packet lane
      // carries it across a public hub. A reference to anything larger would
      // ask every member to fetch it.
      if (meta == null || meta.size > kAvatarMaxBytes) {
        return const XprsGroupOpResult.failed('not a picture this station holds');
      }
    }
    final wires = XprsPublisher.composeDecoration(
      call: g,
      nick: XprsGroupKeys.instance.nickFor(g),
      fileToken: t,
      about: '',
      ts: xprsNowTs(),
      signingKey: scalar,
    );
    if (wires.isEmpty) {
      return const XprsGroupOpResult.failed('the act did not compose or fit');
    }
    final airs = <Future<void>>[];
    for (final w in wires) {
      final p = XprsPacket.parse(w);
      if (p == null) continue;
      // Our own screens see it now: a station never hears itself.
      XprsProfiles.instance.own(g, p);
      airs.add(_air(p));
    }
    // The archive is where the picture is read back from after a restart,
    // and it writes every 20 s. Flushing on an act somebody just tapped is
    // performance.md 8.12's rule: measured here, a restart inside that
    // window came back without the picture.
    unawaited(Future.wait(airs).then((_) => XprsArchive.instance.flush()));
    return XprsGroupOpResult.ok(wires.first);
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

  /// Forget a group entirely: its record, its archived acts, and the key if
  /// we hold one.
  ///
  /// This is local and it is not a deletion. Section 26 has no packet for
  /// "this group is over" and could not honour one — the record is signed and
  /// held by whoever heard it, which is the point. Dropping the key is the
  /// only half 26.6 says a holder can actually do, and even then "the previous
  /// holder keeping a copy is a cost with no protocol answer".
  ///
  /// The archive goes too. The roster is replayed from those rows at startup,
  /// so a group forgotten in memory alone reappears on the next launch, which
  /// reads as the delete not having worked.
  static void forget(String group) {
    final g = group.trim().toUpperCase();
    XprsGroups.instance.forget(g);
    XprsArchive.instance.forgetGroup(g);
    XprsGroupKeys.instance.forget(g);
  }

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
