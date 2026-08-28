/*
 * xprs_graph — the local topology, walked (docs/XPRS.md sections 10.6.3, 36.0).
 *
 * Every station already broadcasts its own one-hop neighbours: a signed
 * `t:observation` carrying `link:<bearer>` and `hears:<callsigns>`. Those are
 * link-state advertisements in all but name, and they are already paid for.
 * XprsGossip retains them; this file is the part that composes two of them
 * into a path, which nothing did before.
 *
 * ── Which way an edge points ────────────────────────────────────────────────
 *
 * `hears:` is about RECEPTION. "A hears B" says B's transmission reaches A,
 * and says nothing about whether A's reaches B. Section 10.6.5 is explicit
 * that the two differ in practice:
 *
 *   "Hearing is also often ASYMMETRIC -- a handheld hears a hilltop repeater
 *    that cannot hear it back. Two stations listing each other can reach each
 *    other; one listing the other cannot, and a client drawing a map should
 *    show the difference."
 *
 * So delivery runs against the arrows. To get a packet from X to Y we need Y
 * to hear X -- an edge whose OBSERVER is Y and whose heard callsign is X.
 * Walking the edges the way they are written would produce paths that look
 * perfect and cannot carry anything, which is the single easiest mistake to
 * make here and the reason it is spelled out.
 *
 * ── What this is not ───────────────────────────────────────────────────────
 *
 * Not a routing table, and not a decision. Section 10.6.3: a station "may list
 * callsigns it cannot hear, and nothing here detects that", which is why
 * `hears:` "informs a choice and never compels one". Nothing in this file
 * changes what any packet does; it changes what an operator can see. The
 * moment a computed path starts being obeyed rather than consulted is the
 * moment section 13.1 has something to say about it.
 */
import 'xprs_gossip.dart';

/// One hop of a candidate path: transmit to [to] on [bearer].
class XprsHop {
  final String to;
  final String bearer;

  /// Age of the evidence for this hop, in milliseconds.
  final int ageMs;

  /// True when we witnessed this hearing ourselves rather than being told.
  final bool direct;
  const XprsHop(this.to, this.bearer, this.ageMs, {this.direct = false});
}

/// A candidate path, and how much it should be believed.
class XprsPath {
  final String from;
  final String to;
  final List<XprsHop> hops;
  const XprsPath(this.from, this.to, this.hops);

  /// Relays between the ends — what section 13.1's budget counts, and what
  /// `via:` would end up holding.
  int get relays => hops.length - 1;

  /// The age of the STALEST evidence on the path. A chain is exactly as
  /// current as its most out-of-date link, and reporting the freshest hop
  /// would flatter a path that has one dead leg in the middle.
  int get worstAgeMs => hops.isEmpty
      ? 0
      : hops.map((h) => h.ageMs).reduce((a, b) => a > b ? a : b);

  bool get allDirect => hops.every((h) => h.direct);

  Map<String, dynamic> json() => {
    'to': to,
    'found': true,
    'hops': [from, ...hops.map((h) => h.to)],
    'bearers': [for (final h in hops) h.bearer],
    'relays': relays,
    'evidenceS': (worstAgeMs / 1000).round(),
    'allDirect': allDirect,
    // Said on every answer, not in the documentation only: this is a
    // reading of other stations' claims, not a route anybody promised.
    'advisory': true,
  };
}

class XprsGraph {
  /// [edges] as stored: `observer` hears `heard`. Traversal reverses them.
  XprsGraph(
    List<GossipEdge> edges, {
    required int nowMs,
    int maxAgeMs = 3600000,
    this.maxRelays = 3,
  }) {
    for (final e in edges) {
      final age = nowMs - e.tsMs;
      // Stale evidence is worse than none: section 36.0 puts reliability above
      // speed precisely because "a fast path that has not carried anything
      // lately is a guess".
      if (age > maxAgeMs || age < 0) continue;
      stations.add(e.observer);
      stations.add(e.heard);
      bearers.add(e.bearer);
      // Reversed on purpose — see the header. e.heard can transmit TO
      // e.observer, because e.observer is the one doing the hearing.
      (_out[e.heard] ??= []).add(_Link(e.observer, e.bearer, age, e.direct));
    }
  }

  /// Section 13.1's budget for ordinary traffic. A longer path is not merely
  /// unattractive, it is one the network would refuse to carry, so there is
  /// no point returning it.
  final int maxRelays;

  final Set<String> stations = {};
  final Set<String> bearers = {};
  final Map<String, List<_Link>> _out = {};

  /// Everything [call] can currently transmit to, with the evidence age.
  List<XprsHop> reachableFrom(String call) => [
    for (final l in _out[call.toUpperCase()] ?? const <_Link>[])
      XprsHop(l.to, l.bearer, l.ageMs, direct: l.direct),
  ];

  /// A candidate path from [from] to [to], or null when the graph does not
  /// contain one.
  ///
  /// Ranked by section 36.0's rule rather than by hop count:
  ///
  ///   "the path with the highest usable bandwidth among those it has recent
  ///    evidence are working ... RELIABILITY OUTRANKS RAW SPEED -- a fast path
  ///    that has not carried anything lately is a guess, and a slower one that
  ///    answered a minute ago is knowledge."
  ///
  /// So the freshest stalest-link wins, and hop count only breaks ties. A
  /// two-hop path built on an hour-old claim loses to a three-hop path every
  /// link of which was confirmed a minute ago.
  XprsPath? pathTo(String to, {required String from}) {
    final src = from.trim().toUpperCase(), dst = to.trim().toUpperCase();
    if (src.isEmpty || dst.isEmpty || src == dst) return null;

    // Bottleneck search: minimise the worst edge age, then the hop count.
    // The graph is a room's worth of stations, so an O(V*E) relaxation is
    // cheaper than the priority queue it would take to avoid it.
    final best = <String, _Cost>{src: const _Cost(0, 0)};
    final prev = <String, XprsHop>{};
    var changed = true;
    while (changed) {
      changed = false;
      for (final entry in _out.entries) {
        final at = best[entry.key];
        if (at == null) continue;
        if (at.hops > maxRelays) continue;
        for (final l in entry.value) {
          final worst = l.ageMs > at.worstAgeMs ? l.ageMs : at.worstAgeMs;
          final cand = _Cost(worst, at.hops + 1);
          if (cand.hops > maxRelays + 1) continue;
          final have = best[l.to];
          if (have != null && !cand.betterThan(have)) continue;
          best[l.to] = cand;
          prev[l.to] = XprsHop(l.to, l.bearer, l.ageMs, direct: l.direct);
          changed = true;
        }
      }
    }
    if (!prev.containsKey(dst)) return null;

    // Walk back. `prev` holds the hop that ARRIVES at each station, so the
    // predecessor is whichever station has an edge to it matching that hop.
    final hops = <XprsHop>[];
    var cur = dst;
    final guard = <String>{};
    while (cur != src) {
      final h = prev[cur];
      if (h == null || !guard.add(cur)) return null;
      hops.insert(0, h);
      final back = _predecessorOf(cur, h, best);
      if (back == null) return null;
      cur = back;
    }
    return XprsPath(src, dst, hops);
  }

  String? _predecessorOf(String node, XprsHop via, Map<String, _Cost> best) {
    String? found;
    var bestCost = const _Cost(1 << 62, 1 << 30);
    for (final entry in _out.entries) {
      final c = best[entry.key];
      if (c == null) continue;
      for (final l in entry.value) {
        if (l.to != node || l.bearer != via.bearer || l.ageMs != via.ageMs) {
          continue;
        }
        if (c.betterThan(bestCost) || found == null) {
          found = entry.key;
          bestCost = c;
        }
      }
    }
    return found;
  }
}

class _Link {
  final String to;
  final String bearer;
  final int ageMs;
  final bool direct;
  const _Link(this.to, this.bearer, this.ageMs, this.direct);
}

class _Cost {
  final int worstAgeMs;
  final int hops;
  const _Cost(this.worstAgeMs, this.hops);

  /// Freshness of the worst link first, hop count only to break the tie.
  bool betterThan(_Cost o) =>
      worstAgeMs != o.worstAgeMs ? worstAgeMs < o.worstAgeMs : hops < o.hops;
}
