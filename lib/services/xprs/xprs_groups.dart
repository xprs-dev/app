/*
 * Closed groups: who belongs, who may act (docs/XPRS.md section 26).
 *
 * A group is a station. It holds a keypair, so it gets an `X5` callsign and
 * announces itself with the ordinary `t:identity` -- there is no group packet,
 * no registry and no creation ceremony (26.1). Everything else is one type:
 *
 *   t:moderate f:<signer> d:<group> ts:<when> grant:<calls> [role:mod|sub]
 *                                             [until:<when>] [since:<when>]
 *                                             [revoke:<calls>] [r:<id> hide:message]
 *
 * `f:` is always the signer and `d:` is always the group the act concerns, so
 * an admin's act and a moderator's act have the same shape and differ only in
 * who signed (26.3).
 *
 * WHY THE ROSTER IS MATERIALISED, not replayed per message. The question this
 * answers -- "may this callsign post in this group?" -- is asked once per
 * inbound packet, and a replay is O(every act ever). That is exactly the shape
 * docs/performance.md section 8.7 calls "a cheap call in a hot loop IS the
 * drain". So the replay runs when an ACT arrives (rare) and the answer is a map
 * lookup (hot). The only other trigger is an `until:` falling due, which is
 * known in advance and checked without work.
 */
import 'dart:typed_data';

import 'xprs_id.dart';
import 'xprs_packet.dart';
import 'xprs_sig.dart';
import 'xprs_vocab.dart';

/// What a callsign is in a group, at a moment.
enum XprsRole {
  /// Not granted, or revoked. Section 26.7: this decides DISPLAY, nothing else.
  none,

  /// Granted, no role word.
  member,

  /// `role:mod` -- may revoke and hide, may NOT appoint (26.3).
  mod,

  /// `role:sub` -- a group listed as part of this one (26.2). Listing confers
  /// no authority and membership does not travel down.
  sub,

  /// The group signing as itself: `f:` equals `d:`. The admin is whoever holds
  /// the group's private key (26.1).
  admin,
}

/// One `t:moderate` act, kept so the replay can be redone when a later act
/// voids part of the record.
class _Act {
  _Act(this.id, this.signer, this.ts, this.grant, this.revoke, this.role,
      this.until, this.since, this.hideRef);

  /// Section 5 identifier -- breaks a tie when two acts share a `ts:` (26.4).
  final String id;
  final String signer;
  final int ts;
  final List<String> grant;
  final List<String> revoke;

  /// `mod`, `sub`, or empty for an ordinary member.
  final String role;
  final int? until;
  final int? since;
  final String hideRef;
}

/// The answer for one group at one moment.
class XprsRoster {
  XprsRoster(this.roles, this.hidden, this.verified);

  final Map<String, XprsRole> roles;

  /// Section 5 identifiers a moderator asked clients not to display.
  final Set<String> hidden;

  /// False when we hold no key for the group. Section 26.7: a client that
  /// cannot verify FAILS OPEN -- it shows everything and says so, because a
  /// closed group whose announcements have not arrived must look broken rather
  /// than empty.
  final bool verified;
}

class XprsGroups {
  XprsGroups._();
  static final XprsGroups instance = XprsGroups._();

  /// Section 26.4: "A `ts:` more than a few minutes in the future is
  /// discarded, or a rogue moderator would win every disagreement for ever by
  /// dating a packet to 2030."
  static const int _futureSlackMs = 5 * 60 * 1000;

  /// Section 26.4: "An `until:` more than a year past its own `ts:` is
  /// discarded for the same reason."
  static const int _maxUntilMs = 366 * 24 * 60 * 60 * 1000;

  /// Section 26.2: "Five levels, counting the root."
  static const int maxDepth = 5;

  /// Bounds. A roster is cheap; ten thousand of them are not.
  static const int _maxGroups = 64;
  static const int _maxActs = 512;

  final Map<String, List<_Act>> _acts = {};
  final Map<String, XprsRoster> _cache = {};

  /// When the cache for a group stops being true because an `until:` falls
  /// due. 0 = nothing pending, so the common case costs one map read.
  final Map<String, int> _nextChange = {};

  int accepted = 0;
  int rejected = 0;
  int unverified = 0;

  /// The callsign→key map, injected the way `XprsArchive.keyResolver` is, so
  /// this file needs no node. Section 26 rests entirely on signatures: an act
  /// nobody can verify must not move a roster, or a stranger could grant
  /// themselves whatever they liked by writing the group's callsign in `f:`.
  Uint8List? Function(String baseCallsign)? keyResolver;

  /// Feed one `t:moderate`. Returns false when the packet is not one, or when
  /// its signature does not stand up.
  bool offer(XprsPacket p, {int? nowMs}) {
    if (p.type != 'moderate') return false;
    final group = (p['d'] ?? '').trim().toUpperCase();
    final signer = (p['f'] ?? '').trim().toUpperCase();
    final ts = xprsParseTs(p['ts']);
    if (group.isEmpty || signer.isEmpty || ts == null) {
      rejected++;
      return false;
    }
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    if (ts > now + _futureSlackMs) {
      rejected++; // dated into the future to win every disagreement
      return false;
    }
    // VERIFY, or it is not an act. `unverified` (we hold no key yet) is kept
    // apart from `forged` on purpose: the first is an ordinary bootstrap state
    // that resolves when the group's `t:identity` arrives, the second is a lie.
    // Neither may change a roster, but only one of them is anybody's fault.
    final state = xprsVerify(p, keyResolver?.call(signer));
    if (state != XprsSigState.verified) {
      if (state == XprsSigState.forged) {
        rejected++;
      } else {
        unverified++;
      }
      return false;
    }

    var until = xprsParseTs(p['until']);
    if (until != null && until - ts > _maxUntilMs) until = null;

    final act = _Act(
      xprsIdentifier(p),
      signer,
      ts,
      _calls(p['grant']),
      _calls(p['revoke']),
      (p['role'] ?? '').trim().toLowerCase(),
      until,
      xprsParseTs(p['since']),
      (p['r'] ?? '').trim(),
    );

    final list = _acts.putIfAbsent(group, () {
      if (_acts.length >= _maxGroups) {
        // Drop the group whose record is oldest. Deliberately crude: a station
        // holding sixty-four rosters is already far past what a phone is for.
        final oldest = _acts.entries.reduce((a, b) =>
            (a.value.isEmpty ? 0 : a.value.last.ts) <=
                    (b.value.isEmpty ? 0 : b.value.last.ts)
                ? a
                : b);
        _forget(oldest.key);
      }
      return <_Act>[];
    });
    if (list.any((a) => a.id == act.id)) return true; // heard it already
    list.add(act);
    if (list.length > _maxActs) {
      // Section 26.5: "losing a grant is safe and losing a revocation is not",
      // so shed a grant before a revocation when the record has to be cut.
      final i = list.indexWhere((a) => a.revoke.isEmpty);
      list.removeAt(i >= 0 ? i : 0);
    }
    accepted++;
    _cache.remove(group);
    _nextChange.remove(group);
    return true;
  }

  void _forget(String group) {
    _acts.remove(group);
    _cache.remove(group);
    _nextChange.remove(group);
  }

  static List<String> _calls(String? v) {
    if (v == null || v.isEmpty) return const [];
    return v
        .split(',')
        .map((c) => c.trim().toUpperCase())
        .where((c) => c.isNotEmpty)
        .toList();
  }

  /// The roster as it stands now. O(1) unless an act arrived or an `until:`
  /// fell due since the last call.
  XprsRoster rosterOf(String group, {int? nowMs, bool haveKey = true}) {
    final g = group.trim().toUpperCase();
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    final due = _nextChange[g] ?? 0;
    final cached = _cache[g];
    if (cached != null && (due == 0 || now < due)) return cached;
    final built = _replay(g, now, haveKey);
    _cache[g] = built;
    return built;
  }

  /// Section 26.7: membership decides DISPLAY and nothing else, and a client
  /// that cannot verify fails open.
  bool mayPost(String group, String callsign,
      {int? nowMs, bool haveKey = true}) {
    final r = rosterOf(group, nowMs: nowMs, haveKey: haveKey);
    if (!r.verified) return true; // fail open, and say so elsewhere
    final role = r.roles[callsign.trim().toUpperCase()] ?? XprsRole.none;
    return role != XprsRole.none && role != XprsRole.sub;
  }

  /// Replay the record. Three passes, and they exist so that two
  /// implementations reach the same answer from the same packets (26.4).
  XprsRoster _replay(String group, int now, bool haveKey) {
    final acts = _acts[group] ?? const <_Act>[];
    if (acts.isEmpty) return XprsRoster({}, {}, haveKey);

    // PASS A -- what the admin voided. "The admin can void a moderator's
    // record": `revoke:X since:T` withdraws X and everything they did from T.
    // Only the group signing as itself can do this, and that test needs no
    // roster, so it can be settled before the walk.
    final voids = <String, int>{};
    for (final a in acts) {
      if (a.signer != group || a.since == null) continue;
      for (final c in a.revoke) {
        final at = a.since!;
        final prev = voids[c];
        if (prev == null || at < prev) voids[c] = at;
      }
    }

    // PASS B -- drop what was voided, then order. Newest wins per signer, and
    // where two acts share a `ts:` the smaller identifier stands, so a tie
    // breaks the same way everywhere.
    final live = <_Act>[];
    for (final a in acts) {
      final from = voids[a.signer];
      if (from != null && a.ts >= from) continue;
      live.add(a);
    }
    live.sort((x, y) => x.ts != y.ts ? x.ts - y.ts : x.id.compareTo(y.id));

    // PASS C -- walk in order. Authority is judged AT THE MOMENT OF THE ACT,
    // so the roles accumulated so far are exactly the right ones to test
    // against: a moderator's revoke counts if they held role:mod then,
    // whatever their status now.
    final roles = <String, XprsRole>{};
    final hidden = <String>{};
    final suspended = <String, int>{}; // callsign -> until
    var nextChange = 0;

    for (final a in live) {
      final isAdmin = a.signer == group;
      final signerRole = roles[a.signer] ?? XprsRole.none;
      final isMod = isAdmin || signerRole == XprsRole.mod;
      if (!isAdmin && !isMod) continue; // no authority at this moment

      // "A moderator may revoke and hide. Only the admin may appoint."
      if (a.grant.isNotEmpty && isAdmin) {
        final role = a.role == 'mod'
            ? XprsRole.mod
            : a.role == 'sub'
                ? XprsRole.sub
                : XprsRole.member;
        for (final c in a.grant) {
          roles[c] = role;
          suspended.remove(c);
        }
      }
      for (final c in a.revoke) {
        if (a.until != null) {
          // A suspension is a revocation with an end. Past its moment it
          // lapses and the grant it interrupted stands again.
          if (a.until! > now) {
            suspended[c] = a.until!;
            if (nextChange == 0 || a.until! < nextChange) nextChange = a.until!;
          }
        } else {
          roles.remove(c);
          suspended.remove(c);
        }
      }
      if (a.hideRef.isNotEmpty) hidden.add(a.hideRef);
    }
    for (final c in suspended.keys) {
      roles[c] = XprsRole.none;
    }
    roles[group] = XprsRole.admin;

    if (nextChange != 0) {
      _nextChange[group] = nextChange;
    } else {
      _nextChange.remove(group);
    }
    return XprsRoster(roles, hidden, haveKey);
  }

  /// For the diagnostics. Counts, never the roster itself -- a status endpoint
  /// that serialises every member of every group is a page fetch to count.
  Map<String, dynamic> statusJson() => {
        'groups': _acts.length,
        'acts': _acts.values.fold<int>(0, (n, l) => n + l.length),
        'accepted': accepted,
        'rejected': rejected,
        'unverified': unverified,
      };

  /// One group, in full -- for `/api/xprs/group?d=X5A3F2`.
  Map<String, dynamic> groupJson(String group, {bool haveKey = true}) {
    final g = group.trim().toUpperCase();
    final r = rosterOf(g, haveKey: haveKey);
    return {
      'group': g,
      'verified': r.verified,
      'acts': (_acts[g] ?? const <_Act>[]).length,
      'roles': {
        for (final e in r.roles.entries) e.key: e.value.name,
      },
      'hidden': r.hidden.toList(),
    };
  }

  void clear() {
    _acts.clear();
    _cache.clear();
    _nextChange.clear();
    accepted = 0;
    rejected = 0;
    unverified = 0;
  }
}
