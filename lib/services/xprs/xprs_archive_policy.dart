/*
 * xprs_archive_policy — what this station keeps, and for whom.
 *
 * XPRS.md 12: "Every device is an archiver; scale is a setting, not a kind. A
 * pocket phone archives its operator's own words and those of the callsigns
 * they follow, and announces nothing. A powered station archives everything it
 * hears… An always-on internet machine does the same at larger budgets." And
 * the rule that governs the third tier: "Silence is not consent: a station
 * holds nothing for strangers until its operator says so."
 *
 * The app had none of that. One boolean (`xprs.archive`, default on) meant
 * "keep everything I hear", and off meant "keep only what is addressed to me".
 * There was no tier between those two, so the phone in a pocket was spooling
 * strangers' Local-room chatter it had never agreed to keep, while the
 * operator's own screen offered no way to say so — and the follow list, which
 * the specification names as the middle tier, was never consulted at all.
 *
 * So the rule is three tiers, and it is a pure function of facts the caller
 * already has:
 *
 *   mine            my own traffic, my mail, my groups     always
 *   people I follow their conversation, every lane          keepFollowed
 *   everyone else   strangers                               public only
 *
 * Pure on purpose (docs/architecture.md 3): the decision belongs to the core,
 * and a decision that cannot be tested is a guess. It reads no preferences —
 * the caller passes an immutable [XprsArchivePolicy] snapshot, which is also
 * what keeps the receive funnel off the preference store (docs/performance.md
 * 4.2: the ingest path is the hottest in the app).
 */
library;

import '../social/retention_tier.dart';

/// Types no station spools, whatever its tiers say: an acknowledgement, a
/// result and a reachability test are answers, not records. Defined here
/// rather than beside the database because it is part of the rule, and this
/// file is the rule.
const Set<String> kXprsNeverArchived = {'ping', 'pong', 'receipt', 'result'};

/// Traffic that is only true while it is fresh. Held for a stranger it is
/// storage spent on a statement about a moment that has passed; an archiver
/// that serves `cmd:history kind:observation` wants it, a phone does not.
bool xprsIsPresenceType(String type) =>
    type == 'observation' || type == 'service';

/// The operator's standing answer to "what do you keep, and for whom".
///
/// Immutable and cheap to hold: built once from preferences when one of them
/// changes, never read per packet.
class XprsArchivePolicy {
  const XprsArchivePolicy({
    this.public = false,
    this.alwaysOn = false,
    this.keepFollowed = true,
    this.keepChatter = false,
  });

  /// Keep strangers' traffic, within the quota, and announce `serve:archive`.
  /// Off is the pocket default: silence is not consent (XPRS.md 12).
  final bool public;

  /// The further promise a plugged-in machine makes: larger budgets, gossip
  /// for every callsign, a deposit point for other people's mail. Only
  /// meaningful when [public] is on, and the preference getter enforces that.
  final bool alwaysOn;

  /// Keep the conversation of the callsigns this operator follows. The middle
  /// tier, and the one the specification says a pocket phone is for.
  final bool keepFollowed;

  /// Keep presence traffic (`t:observation`, `t:service`) as well. An
  /// always-on archiver's stock in trade — a `cmd:history kind:observation`
  /// replay may only re-air original packets, so a station that discarded them
  /// answers every such ask with a 404 by construction.
  final bool keepChatter;

  XprsArchivePolicy copyWith({
    bool? public,
    bool? alwaysOn,
    bool? keepFollowed,
    bool? keepChatter,
  }) =>
      XprsArchivePolicy(
        public: public ?? this.public,
        alwaysOn: alwaysOn ?? this.alwaysOn,
        keepFollowed: keepFollowed ?? this.keepFollowed,
        keepChatter: keepChatter ?? this.keepChatter,
      );
}

/// Which shelf this packet goes on, or null to let it pass unrecorded.
///
/// The returned [Tier] is stored with the row and is what retention reads
/// later: `self` and `followed` are exempt from the caps, `stranger` is what
/// the quota bounds and what eviction takes first.
///
/// - [tier] is who sent it, as the caller already knows: `self` for our own
///   traffic and anything addressed to us or to a group we are in.
/// - [publication] is a packet meant for anybody — a status, a reaction, an
///   undirected message.
/// - [declared] is mail whose either end has an active `t:mailbox hold:`
///   naming this station (13.12).
/// - [internet] says the packet arrived over Reticulum, where the declaration
///   rule applies: a hub replays the world at us and we do not spool the world.
Tier? xprsAdmitTier({
  required Tier tier,
  required String type,
  required bool publication,
  required bool declared,
  required bool internet,
  required XprsArchivePolicy policy,
  /// `d:` names this station. Mail addressed to us is ours whatever its type:
  /// an observation somebody sent US is an answer, not chatter.
  bool addressedToUs = false,
}) {
  // Never spooled by anybody: acknowledgements, results and reachability
  // tests. The archive drops these at its own door too; naming them here
  // keeps the rule readable on its own.
  if (kXprsNeverArchived.contains(type)) return null;

  // A KEY BINDING IS NOT CHATTER. `t:identity` is what makes every other
  // packet from that station checkable — a signature verifiable (9.1), a
  // message sealable (9.2), a receipt trustworthy (13.7.1). Discarding it is
  // discarding the reason it was sent (18.1), and it is bounded by
  // XprsArchive._collapseIdentities.
  if (type == 'identity') return tier;

  final presence = xprsIsPresenceType(type);
  final chatterOk = policy.alwaysOn || policy.keepChatter;

  // ── Mine. Never governed by any switch: my mail, whatever shape it takes,
  // and my groups' acts, which are the only record of a roster (26.4).
  if (tier == Tier.self) {
    if (addressedToUs) return Tier.self;
    // Our own beacons are the exception: nobody has ever asked a phone to
    // replay its own presence, and on the bench they were 139 of the newest
    // 200 rows in this device's archive.
    return (!presence || chatterOk) ? Tier.self : null;
  }

  // ── People I follow. Their conversation is what a pocket archiver is FOR,
  // so it needs no declaration even off the internet: a followed friend's
  // publications reaching us through a hub are exactly what we meant to keep.
  if (tier == Tier.followed && policy.keepFollowed) {
    return (!presence || chatterOk) ? Tier.followed : null;
  }

  // ── Everyone else. Silence is not consent (12): with Public archiver off
  // this station holds nothing for strangers — not their chatter, not their
  // publications, and not mail that merely names us in somebody's `hold:`.
  if (!policy.public) return null;

  if (presence) return chatterOk ? Tier.stranger : null;

  // On the internet a stranger's traffic is admitted only under the
  // declaration rule: publications, mail either side of which declared us, or
  // anything at all when this station is always on and has the budget for it.
  if (internet && !(publication || declared || policy.alwaysOn)) return null;

  return Tier.stranger;
}
