/// Owning a station, and what the owner sets (`docs/XPRS.md` section 25.9).
///
/// Pure: no radio, no disk, no isolate. What lives here is the wire shape of
/// a claim, a policy command and a policy ask; the decision of whether a claim
/// is accepted; the replay rule that keeps a year-old `cmd:set owner:` from
/// handing a station back; and the ONE send order every station that queues
/// for others must use. The station side (an ESP32 storing this in NVS and
/// airing by it) is not implemented; the status table in section 37 says so.
library;

import 'xprs_id.dart';
import 'xprs_packet.dart';
import 'xprs_vocab.dart';

/// The most callsigns `owner:` may name (section 25.9: "a list that names
/// four is full"). The ESP32 has exactly four slots, `own1..own4`.
const int kXprsOwnersMax = 4;

/// A station's policy: the four keys of section 25.9, as the station holds
/// them and as a `q:policy` answer or a `cmd:set` result reports them.
class XprsStationPolicy {
  final List<String> owners;
  final String use;
  final List<String> first;
  final List<String> serve;

  /// `ts:` of the last policy command accepted, for the replay rule. Null on a
  /// station that has never been told anything.
  final String? ts;

  const XprsStationPolicy({
    this.owners = const [],
    this.use = 'all',
    this.first = const [],
    this.serve = const [],
    this.ts,
  });

  bool get owned => owners.isNotEmpty;

  bool isOwner(String call) => owners.contains(_norm(call));

  bool isFirst(String call) => first.contains(_norm(call));

  /// Section 25.9 `use:`: may [call] originate traffic through this station?
  /// `t:sos` and `t:warning` are aired for anyone whatever this says, and that
  /// is decided by the caller with [xprsAlwaysAired], not here.
  bool mayUse(String call) => switch (use) {
        'all' => true,
        'owners' => isOwner(call),
        'listed' => isOwner(call) || isFirst(call),
        _ => false, // none, and anything unknown reads as the strictest
      };

  /// Read the policy a packet carries: a `t:observation s:policy`, a
  /// `t:result` to a policy command, or the command itself. Absent keys take
  /// [base] (unchanged, section 25.9) or the defaults.
  factory XprsStationPolicy.fromPacket(XprsPacket p,
      {XprsStationPolicy base = const XprsStationPolicy()}) {
    final owner = p['owner'];
    final use = p['use'];
    final first = p['first'];
    final serve = p['serve'];
    return XprsStationPolicy(
      owners: owner == null ? base.owners : _path(owner, max: kXprsOwnersMax),
      use: use == null
          ? base.use
          : (kXprsUseModes.contains(use) ? use : base.use),
      first: first == null ? base.first : _path(first),
      serve: serve == null ? base.serve : _serve(serve),
      ts: p['ts'] ?? base.ts,
    );
  }

  /// The four keys in a fixed order, `owner: use: first: serve:`, as a result
  /// or observation carries them. Every key is present because a result states
  /// what IS, all of it (section 25.9); an empty list is `none`.
  String toKeys() => 'owner:${owners.isEmpty ? 'none' : owners.join(',')} '
      'use:$use '
      'first:${first.isEmpty ? 'none' : first.join(',')} '
      'serve:${serve.isEmpty ? 'none' : serve.join(',')}';

  /// This policy with the keys [cmd] carries applied over it.
  XprsStationPolicy merge(XprsPacket cmd) =>
      XprsStationPolicy.fromPacket(cmd, base: this);

  static String _norm(String c) => c.trim().toUpperCase();

  static List<String> _path(String v, {int? max}) {
    if (v == 'none') return const [];
    final out = <String>[];
    for (final c in v.split(',')) {
      final n = _norm(c);
      if (n.isEmpty || out.contains(n)) continue;
      out.add(n);
      if (max != null && out.length >= max) break;
    }
    return out;
  }

  static List<String> _serve(String v) {
    if (v == 'none') return const [];
    return v
        .split(',')
        .map((w) => w.trim().toLowerCase())
        .where(kXprsServices.contains)
        .toList();
  }
}

// ── Wires ──────────────────────────────────────────────────────────────────
//
// Each returns the unsigned wire, or null when it does not fit 250 bytes. The
// caller signs (xprs_sig.dart) and publishes (XprsPublisher.publishWire); a
// builder that also transmitted would be one more place deciding how bytes
// travel, and the transports are the core's.

/// What an unowned station airs: `t:request q:owner scope:local`.
String? xprsClaimAskWire(String station, {String? ts}) =>
    _fit('t:request f:$station q:owner scope:local ts:${ts ?? xprsNowTs()}');

/// The claim: `cmd:set owner:<self>`, the signer naming itself.
String? xprsClaimWire(String self, String station, {String? ts}) =>
    xprsPolicySetWire(self, station, owners: [self], ts: ts);

/// A policy command carrying only the keys given (absent = unchanged).
String? xprsPolicySetWire(
  String self,
  String station, {
  List<String>? owners,
  String? use,
  List<String>? first,
  List<String>? serve,
  String? ts,
}) {
  final b = StringBuffer(
      't:command f:$self d:$station ts:${ts ?? xprsNowTs()} cmd:set');
  if (owners != null) b.write(' owner:${_list(owners)}');
  if (use != null) b.write(' use:$use');
  if (first != null) b.write(' first:${_list(first)}');
  if (serve != null) b.write(' serve:${_list(serve)}');
  return _fit(b.toString());
}

/// `t:request q:policy`: anyone may ask.
String? xprsPolicyAskWire(String self, String station, {String? ts}) =>
    _fit('t:request f:$self d:$station ts:${ts ?? xprsNowTs()} q:policy');

/// The answer to [xprsPolicyAskWire]: `t:observation s:policy` with all four.
String? xprsPolicyReportWire(
        String station, String to, XprsStationPolicy p, {String? ts}) =>
    _fit('t:observation f:$station d:$to s:policy ${p.toKeys()} '
        'ts:${ts ?? xprsNowTs()}');

String _list(List<String> l) => l.isEmpty ? 'none' : l.join(',');

String? _fit(String wire) {
  final p = XprsPacket.parse(wire);
  return (p == null || !p.fits) ? null : wire;
}

// ── Decisions ──────────────────────────────────────────────────────────────

/// Is this `cmd:set` a policy command at all: does it carry any of the four?
bool xprsIsPolicyCommand(XprsPacket p) =>
    p.type == 'command' &&
    p['cmd'] == 'set' &&
    kXprsPolicyKeys.any(p.has);

/// Section 25.9 on a claim or an owner change. [verified] is the signature
/// verdict the caller already has (section 25.4: an unverified command is
/// discarded, never answered — so this returns 403 for it only to keep one
/// table of answers; the caller drops it).
///
/// Returns the result code: 200 when the command may change `owner:`, 403
/// otherwise. Uncarried is `via:` absent — the requirement of 25.4 that here
/// stops a claim being made from across the country.
int xprsClaimCode(XprsPacket cmd,
    {required XprsStationPolicy policy, required bool verified}) {
  if (!verified) return 403;
  final owner = cmd['owner'];
  if (owner == null) return 400;
  if (xprsVia(cmd).isNotEmpty) return 403;
  final f = (cmd['f'] ?? '').toUpperCase();
  if (f.isEmpty) return 403;
  if (!policy.owned) {
    final named = XprsStationPolicy.fromPacket(cmd).owners;
    return named.contains(f) ? 200 : 403;
  }
  return policy.isOwner(f) ? 200 : 403;
}

/// Any policy key other than a first claim: owners only.
int xprsPolicyCode(XprsPacket cmd,
    {required XprsStationPolicy policy, required bool verified}) {
  if (!verified) return 403;
  if (!xprsIsPolicyCommand(cmd)) return 400;
  if (cmd.has('owner')) {
    final c = xprsClaimCode(cmd, policy: policy, verified: verified);
    if (c != 200) return c;
  } else if (!policy.isOwner(cmd['f'] ?? '')) {
    return 403;
  }
  return xprsPolicyReplayCode(policy.ts, cmd['ts']) ?? 200;
}

/// The replay rule: a policy command whose `ts:` is not later than the last
/// accepted one is 408, whatever the clock says now. Null when it may proceed.
///
/// `ts:` is `YYYY-MM-DD_hh:mm:ss` UTC (section 4.3), so string order is time
/// order and no parsing is needed.
int? xprsPolicyReplayCode(String? lastTs, String? ts) {
  if (ts == null || ts.isEmpty) return 408;
  if (lastTs == null || lastTs.isEmpty) return null;
  return ts.compareTo(lastTs) > 0 ? null : 408;
}

/// Aired for anyone whatever `use:` says (section 25.9).
bool xprsAlwaysAired(XprsPacket p) => p.type == 'sos' || p.type == 'warning';

/// The send order of section 25.9, as a comparator: negative when [a] airs
/// before [b]. Fixed by the document; the owner fills in `first:`.
///
///  1. `t:sos` and `t:warning`;
///  2. `f:` in `first:`;
///  3. `urg:`, a stranger's counted no higher than `high`;
///  4. `ts:`, oldest first.
int xprsSendOrder(XprsPacket a, XprsPacket b, XprsStationPolicy p) {
  final sa = xprsAlwaysAired(a) ? 0 : 1;
  final sb = xprsAlwaysAired(b) ? 0 : 1;
  if (sa != sb) return sa - sb;

  final fa = p.isFirst(a['f'] ?? '') ? 0 : 1;
  final fb = p.isFirst(b['f'] ?? '') ? 0 : 1;
  if (fa != fb) return fa - fb;

  final ua = _urg(a, p).index;
  final ub = _urg(b, p).index;
  if (ua != ub) return ub - ua; // higher urgency first

  return (a['ts'] ?? '').compareTo(b['ts'] ?? '');
}

XprsUrgency _urg(XprsPacket x, XprsStationPolicy p) {
  final u = XprsUrgency.fromWire(x['urg']);
  final f = x['f'] ?? '';
  final known = p.isOwner(f) || p.isFirst(f);
  return known ? u : u.cappedAt(XprsUrgency.high);
}

/// Stations heard asking for an owner (`t:request q:owner` from an `X3`),
/// kept so a screen can later offer to claim one. Plain memory, no listener:
/// a page that shows it polls it, and nothing else reads it.
class XprsUnownedStations {
  XprsUnownedStations._();
  static final XprsUnownedStations instance = XprsUnownedStations._();

  final Map<String, String> _lastHeard = {};

  /// callsign → the `ts:` it last asked with (or the packet's id when it has
  /// none), most recent ask kept.
  Map<String, String> get heard => Map.unmodifiable(_lastHeard);

  /// True when [p] was an ask and is now recorded.
  bool note(XprsPacket p) {
    if (p.type != 'request' || p['q'] != 'owner') return false;
    final f = (p['f'] ?? '').toUpperCase();
    if (!f.startsWith('X3')) return false;
    _lastHeard[f] = p['ts'] ?? xprsIdentifier(p);
    return true;
  }

  /// Once claimed (or gone), it stops being offered.
  void forget(String station) => _lastHeard.remove(station.toUpperCase());

  void clear() => _lastHeard.clear();
}
