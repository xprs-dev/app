/*
 * xprs_observation — this station's reachability claim, and when to say it
 * to its archivers (XPRS.md 12.1, 15.6.3).
 *
 * A gateway's own `t:observation` is a reachability record: `f:` says which
 * gateway, `hears:` the stations at its ear now, `link:` which radio, `ts:`
 * how fresh. On the radio every beacon already says it. What was missing is
 * the copy that travels: pushed to the archivers this station chose, over
 * Reticulum, as an addressed deposit (12.12.2 -- an undirected packet on a
 * shared hub is an announce nobody forwards). That copy is what lets an
 * archiver on another continent learn "X1BOA3 is at X3RLY7's ear, on
 * Bluetooth" and hand X1BOA3's mail to X3RLY7 (12.8.1), which is the whole
 * APRS-IS-like loop with no central server in it.
 *
 * Two pieces, both pure so they are tested without a radio:
 *
 *   xprsComposeObservation  the packet, signed, with `hears:` cut to the
 *                           budget and `peers:` the true total (15.6.4).
 *                           The LAN beacon and the deposit are the same
 *                           packet built against different budgets.
 *   XprsHearsReporter       WHEN to deposit: at once when a station appears
 *                           at our ear that the last report did not name
 *                           (that is the event a holder of its mail is
 *                           waiting for), else on a period, and never more
 *                           than once a minute. Silence costs nothing and
 *                           says nothing: no neighbours, no report.
 *
 * The firmware station has done this since its archiver work
 * (xprs_app.c air_signed_observations): a phone as the gateway did not,
 * which is why a BLE-only station next to a phone was unreachable from the
 * internet unless the phone happened to share a LAN with the archiver.
 */
library;

import 'xprs_packet.dart';
import 'xprs_sig.dart';
import 'xprs_vocab.dart';

/// Build this station's observation about one radio.
///
/// [heard] is who was heard directly on [link], most relevant first; the
/// list is cut to what fits [budget] with `peers:` keeping the full count.
/// Room for the signature is reserved before the fit (` sig:` plus 60
/// base85 characters is 65 bytes), so the SIGNED packet fits the budget.
/// Null when there is no callsign to speak as, or nothing fits at all.
XprsPacket? xprsComposeObservation({
  required String self,
  required String link,
  required List<String> heard,
  required int budget,
  int mail = 0,
  String? lx,
  int? uptimeS,
  int? lifetimeS,
  String? serve,
  BigInt? signingKey,
  String? ts,
}) {
  final me = self.trim();
  if (me.isEmpty) return null;
  var envelope = XprsPacket.parse('t:observation f:$me link:$link');
  if (envelope == null) return null;
  if (mail > 0) envelope = envelope.with_('mail', '$mail');
  if (lx != null && lx.length == 32) envelope = envelope.with_('lx', lx);
  if (uptimeS != null) {
    envelope = envelope.with_('uptime', xprsFmtDuration(uptimeS));
  }
  if (lifetimeS != null) {
    envelope = envelope.with_('lifetime', xprsFmtDuration(lifetimeS));
  }
  if (serve != null && serve.isNotEmpty) envelope = envelope.with_('serve', serve);
  if (ts != null) envelope = envelope.with_('ts', ts);

  final room = budget - (signingKey != null ? 65 : 0);
  final fit = xprsNeighbourFit(heard, envelope, room);
  var p = envelope.with_('peers', '${fit.peers}');
  if (fit.hears.isNotEmpty) p = p.with_('hears', fit.hears.join(','));
  if (signingKey != null) p = xprsSign(p, signingKey);
  return p.fits ? p : null;
}

/// When this station's hearing is worth a deposit with its archivers.
///
/// Pure: hand it who is heard now and the clock, and it answers why a report
/// is due ("new" or "period") or that none is. It remembers what the last
/// report named, which is what makes a NEW arrival detectable.
class XprsHearsReporter {
  XprsHearsReporter({
    this.period = const Duration(minutes: 5),
    this.minGap = const Duration(minutes: 1),
  });

  /// How often the claim is repeated while somebody is heard (a live
  /// sighting expires in the archiver's table, 12.9.4's L3 TTL, and a
  /// repeated claim keeps it fresh without a new packet type).
  final Duration period;

  /// Never faster than this, whatever appears: a crowd arriving one by one
  /// is one report a minute, not one per arrival.
  final Duration minGap;

  Set<String> _reported = const {};
  int _lastMs = 0;
  int reports = 0;

  /// What the last report named, bare and uppercase.
  Set<String> get reported => _reported;

  /// `'new'` when a station is heard that the last report did not name,
  /// `'period'` when the period has elapsed, null when nothing is due. An
  /// empty [heardNow] is never due: a claim of nobody is airtime for nobody.
  String? due(Iterable<String> heardNow, int nowMs) {
    final now = <String>{
      for (final c in heardNow)
        if (c.trim().isNotEmpty) c.trim().toUpperCase().split('-').first,
    };
    if (now.isEmpty) return null;
    final since = nowMs - _lastMs;
    if (_lastMs != 0 && since < minGap.inMilliseconds) return null;
    if (_lastMs == 0 || since >= period.inMilliseconds) return 'period';
    if (now.any((c) => !_reported.contains(c))) return 'new';
    return null;
  }

  /// A report went out naming [heardNow] at [nowMs].
  void noteReported(Iterable<String> heardNow, int nowMs) {
    _reported = {
      for (final c in heardNow) c.trim().toUpperCase().split('-').first,
    };
    _lastMs = nowMs;
    reports++;
  }

  void reset() {
    _reported = const {};
    _lastMs = 0;
    reports = 0;
  }
}
