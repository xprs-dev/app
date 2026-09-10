/*
 * xprs_archiver_choice — the archiver a station leans on when its operator
 * named none.
 *
 * XPRS.md 12.3 leaves this open on purpose: "A station naming none MAY let one
 * be auto-selected, a volunteer advertising `serve:archive` that accepts it;
 * naming one explicitly overrides that." The preference for it has existed
 * since the archiver work began and nothing ever implemented the choosing, so
 * a fresh phone had an empty list, deposited its mail nowhere, and a message
 * written while the recipient was asleep died with the sender's next screen
 * lock.
 *
 * The choice is deliberately dull. It is not a ranking of who is BEST — a
 * station cannot know that — it is a rule for picking one volunteer and
 * sticking with it, because the value of an archiver is entirely in being the
 * same one tomorrow. The rule, in order:
 *
 *   1. never ourselves, and never a group;
 *   2. it must claim `serve:archive` (24) in something we heard;
 *   3. an internet bearer beats a radio one — the point of leaning on an
 *      archiver is that it is there when we are not, and a station we only
 *      ever heard over BLE is by definition one we have to be near;
 *   4. heard recently, or the claim is a memory rather than an offer;
 *   5. longest uptime where it is stated (10.6), then freshest.
 *
 * Keeping the choice is as important as making it: a station that re-picks
 * every hour spreads its mail over every volunteer it ever heard, and none of
 * them holds the whole conversation. So an adopted archiver is kept until it
 * goes silent for [kForgetAfter], and the operator naming one at any time
 * overrides all of this (12.3: "the depositor chooses too").
 */
library;

/// One station that says it archives, as this station heard it.
class ArchiverOffer {
  const ArchiverOffer({
    required this.callsign,
    required this.lastHeardMs,
    required this.bearer,
    this.uptimeS = 0,
  });

  final String callsign;
  final int lastHeardMs;

  /// The bearer it was last heard on: `rns`, `lan`, `ble`, `lora`.
  final String bearer;

  /// `uptime:` where the station stated one (10.6), 0 when it did not.
  final int uptimeS;

  /// An archiver reached over the internet is one we can lean on while we are
  /// nowhere near it. A LAN peer is the same argument at village scale; a
  /// radio one is not, and is only ever a fallback.
  bool get offGrid => bearer == 'ble' || bearer == 'ble5' || bearer == 'lora';
}

class XprsArchiverChoice {
  XprsArchiverChoice._();
  static final XprsArchiverChoice instance = XprsArchiverChoice._();

  /// A volunteer unheard for this long is no longer a volunteer.
  static const Duration kForgetAfter = Duration(hours: 12);

  /// How stale a claim may be and still count as an offer.
  static const Duration kFreshFor = Duration(hours: 6);

  int adopted = 0, dropped = 0, kept = 0;

  /// Pick one volunteer, or null when none qualifies.
  ///
  /// [current] is what we adopted last time: it wins against a newcomer unless
  /// it has gone silent, because switching archivers loses the thread.
  static String? pick(
    List<ArchiverOffer> offers, {
    required String selfBase,
    required int nowMs,
    String? current,
  }) {
    final self = selfBase.trim().toUpperCase();
    final fresh = [
      for (final o in offers)
        if (o.callsign.trim().isNotEmpty &&
            o.callsign.trim().toUpperCase() != self &&
            nowMs - o.lastHeardMs <= kFreshFor.inMilliseconds)
          o,
    ];
    if (current != null && current.trim().isNotEmpty) {
      final cur = current.trim().toUpperCase();
      final still = fresh.where((o) => o.callsign.toUpperCase() == cur);
      // Kept unless it has been silent past the forget window — and "not in
      // the fresh list" is not silence, it is only "not heard lately".
      final seen = offers.where((o) => o.callsign.toUpperCase() == cur);
      if (still.isNotEmpty ||
          (seen.isNotEmpty &&
              nowMs - seen.first.lastHeardMs <= kForgetAfter.inMilliseconds)) {
        return cur;
      }
      // NOTHING BETTER TO MOVE TO: keep the one we have.
      //
      // An archiver is replaced when a live volunteer is there to replace it
      // with — not because the offers list is empty. On a station with no
      // local neighbours the list is empty BY CONSTRUCTION: offers are built
      // from stations heard on the air, and a phone on mobile data hears
      // nobody, so its archiver aged out of the table and was dropped while it
      // was still perfectly reachable over the internet. Measured on the bench
      // (X1WATT, 5G, 2026-09-10): adopted X1ARKL, dropped it minutes later,
      // and its next post was deposited nowhere — which is the one thing the
      // deposit exists to prevent (XPRS.md 12: a station hands a COPY to the
      // archivers its operator chose). Keeping a stale name costs a failed
      // send that `depositNoDest` counts; dropping it costs the publication.
      if (fresh.isEmpty) return cur;
    }
    if (fresh.isEmpty) return null;
    fresh.sort((a, b) {
      if (a.offGrid != b.offGrid) return a.offGrid ? 1 : -1;
      if (a.uptimeS != b.uptimeS) return b.uptimeS.compareTo(a.uptimeS);
      return b.lastHeardMs.compareTo(a.lastHeardMs);
    });
    return fresh.first.callsign.trim().toUpperCase();
  }

  /// Apply [pick] to this station's configuration.
  ///
  /// Returns the callsign now in force, or null when the station has (and
  /// should have) none. Does nothing at all when the operator named an
  /// archiver — an explicit choice is never second-guessed — or when they
  /// turned auto-selection off.
  String? reconsider({
    required List<ArchiverOffer> offers,
    required String selfBase,
    required bool autoEnabled,
    required List<String> configured,
    required String? adoptedNow,
    required void Function(String? callsign) adopt,
    int? nowMs,
  }) {
    final explicit = configured
        .map((c) => c.trim().toUpperCase())
        .where((c) => c.isNotEmpty && c != adoptedNow?.toUpperCase())
        .toList();
    if (!autoEnabled || explicit.isNotEmpty) {
      if (adoptedNow != null) {
        // The operator has spoken since we adopted one; stand down.
        adopt(null);
        dropped++;
      }
      return explicit.isEmpty ? null : explicit.first;
    }
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    final choice =
        pick(offers, selfBase: selfBase, nowMs: now, current: adoptedNow);
    if (choice == adoptedNow) {
      if (choice != null) kept++;
      return choice;
    }
    adopt(choice);
    if (choice == null) {
      dropped++;
    } else {
      adopted++;
    }
    return choice;
  }
}
