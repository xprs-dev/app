/*
 * xprs_cadence — how often to ask one archiver for news.
 *
 * Every station used to ask every archiver on the same clock, forever: a room
 * nobody had spoken in for three months cost the same metered replay as one
 * with a conversation running. On a super-archiver -- the station everybody
 * pulls Global chat from -- that fixed clock IS the load.
 *
 * So the interval follows the room. What an archiver returns is the only
 * honest measure of how busy it is, and it is a measure we get for free: the
 * answer is already coming back. Rows -> come sooner. Nothing -> come later.
 *
 * The two bounds are not ours to choose:
 *
 *  - The CEILING is how long the archiver has been silent (the ladder below).
 *    Something that has said nothing for three months does not need asking
 *    every ten minutes.
 *  - The FLOOR is what the peer permits. Section 31.2 lets an ordinary
 *    archiver answer a known caller six times an hour, and section 36.10.1
 *    says plainly that the ten-minute poll is exactly that ceiling and not an
 *    arbitrary number. Only a super-archiver's raised budgets (36.9.4) can
 *    serve a fast caller, so only a super-archiver gets one. A station that
 *    polls an ordinary peer faster steals that peer's whole cross-caller
 *    allowance and 429-starves everyone else asking it.
 *
 * And a 429 is not noise: it is the peer telling us our cadence is wrong. It
 * is the one answer that must always slow us down.
 *
 * Pure functions, no clock and no I/O of their own, so the ladder is testable
 * without a radio (docs/performance.md section 8.5: a poll interval is a
 * battery setting and has to be justified as one).
 */
library;

/// What an archiver's last answer was worth.
enum XprsAnswer {
  /// It served rows we had not seen. It is talking.
  news,

  /// It answered, and there was nothing new (200 with nothing, or 404).
  quiet,

  /// Over budget (429). The peer is the authority on how often it will answer.
  refused,
}

/// How reachable this archiver is, which decides how fast we may ask it.
enum XprsPeerClass {
  /// `serve:archive,super` (36.9.4), or another of our own devices -- which
  /// the responder does not meter at all. These can absorb a fast caller.
  fast,

  /// Any other archiver: section 31.2's reference budgets apply.
  ordinary,
}

class XprsCadence {
  XprsCadence._();

  /// The fast floor. Not lower, because a page takes about eighteen seconds to
  /// air (twelve records at the responder's pacing) and one replay runs at a
  /// time: an ask that lands mid-chain is refused, so asking faster than the
  /// peer can answer buys 429s instead of news.
  static const Duration fastFloor = Duration(seconds: 15);

  /// The ordinary floor, and the ceiling for an archiver that has been quiet
  /// less than a week: section 36.10.1's ten minutes.
  static const Duration ordinaryFloor = Duration(minutes: 10);

  /// Nobody is looking. Anything faster than the ordinary floor is spending
  /// somebody's battery on news no one is awake to read (performance.md 6.5).
  static const Duration hiddenFloor = Duration(minutes: 10);

  /// The ladder: the longer an archiver has had nothing to say, the less
  /// often it is worth asking.
  static const Duration ceilingFresh = Duration(minutes: 10);
  static const Duration ceilingWeek = Duration(minutes: 60);
  static const Duration ceilingQuarter = Duration(hours: 6);

  static const Duration weekSilent = Duration(days: 7);
  static const Duration quarterSilent = Duration(days: 90);

  /// A 429 never leaves us asking more than once a minute, whatever the
  /// interval was before it.
  static const Duration refusedMin = Duration(minutes: 1);

  /// The slowest we will ever ask, so a fresh archiver is not asked at six
  /// hours just because it has not spoken yet.
  static Duration ceilingFor(Duration silentFor) {
    if (silentFor >= quarterSilent) return ceilingQuarter;
    if (silentFor >= weekSilent) return ceilingWeek;
    return ceilingFresh;
  }

  static Duration floorFor(XprsPeerClass peer, {required bool visible}) {
    if (!visible) return hiddenFloor;
    return peer == XprsPeerClass.fast ? fastFloor : ordinaryFloor;
  }

  /// The next interval for an archiver, given what it just answered.
  ///
  /// Halve on news and double on quiet -- the same shape the mesh scheduler
  /// already uses for a peer visit that gains nothing
  /// (mesh_transfer_scheduler.dart), because it is the right one: it converges
  /// fast when a room wakes up and decays gently when it does not.
  static Duration next({
    required Duration current,
    required XprsAnswer answer,
    required XprsPeerClass peer,
    required bool visible,
    required Duration silentFor,
  }) {
    final floor = floorFor(peer, visible: visible);
    final ceiling = ceilingFor(silentFor);
    // A ladder step can put the ceiling below the floor (an ordinary peer
    // silent for a week wants 60 min, its floor is 10 min): the ceiling wins,
    // because asking less often is always allowed and asking more often is
    // what the budgets forbid.
    Duration clamp(Duration d) {
      if (d > ceiling) return ceiling;
      if (d < floor) return floor > ceiling ? ceiling : floor;
      return d;
    }

    switch (answer) {
      case XprsAnswer.news:
        return clamp(current ~/ 2);
      case XprsAnswer.quiet:
        return clamp(current * 2);
      case XprsAnswer.refused:
        // Deliberately not clamped to the floor: being refused means our floor
        // was wrong for this peer, so the answer is to back off past it.
        final base = current < refusedMin ? refusedMin : current;
        final backed = base * 2;
        return backed > ceiling ? ceiling : backed;
    }
  }

  /// The interval to start an archiver on: the ordinary floor, so a station we
  /// have never asked is polite by default and earns its speed.
  static Duration get initial => ordinaryFloor;

  /// Spread the herd. Many devices pulling one super-archiver on the same
  /// interval arrive together, which is the load pattern this file exists to
  /// avoid; a tenth either way is enough to smear them and is invisible to a
  /// reader. [rand] is a 0..1 sample, injected so tests are deterministic.
  static Duration jitter(Duration d, double rand) {
    final delta = (d.inMilliseconds * 0.1 * (rand * 2 - 1)).round();
    final ms = d.inMilliseconds + delta;
    return Duration(milliseconds: ms < 1000 ? 1000 : ms);
  }
}
