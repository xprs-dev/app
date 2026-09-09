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
    // X2 or X3: a ship is claimed the way a rooftop relay is (section 3).
    if (!f.startsWith('X2') && !f.startsWith('X3')) return false;
    _lastHeard[f] = p['ts'] ?? xprsIdentifier(p);
    return true;
  }

  /// Once claimed (or gone), it stops being offered.
  void forget(String station) => _lastHeard.remove(station.toUpperCase());

  void clear() => _lastHeard.clear();
}

/// What this station claims on the air, or null when it claims nothing.
///
/// XPRS.md 13's `serve:` vocabulary is a fixed set, and `archive` is the only
/// word for the archiver role — there is nothing above it. The app used to air
/// `archive,super`, a word no other implementation would recognise, to mean
/// "always on"; 12.9.4 answers that directly: an always-on archiver is
/// addressable, deep, budgeted, concurrent, complete and awake, and "None of
/// this is a separate role." A peer works it out from `count:`, `uptime:` and
/// whether it can be reached — see [xprsLooksAlwaysOn].
///
/// The claim is also honest about files now: `files` used to ride along with
/// `archive` unconditionally, on phones hosting nothing.
String? xprsServeClaim({
  required bool public,
  required bool spoolReady,
  required bool files,
}) {
  final words = <String>[
    if (public && spoolReady) 'archive',
    if (files) 'files',
  ];
  return words.isEmpty ? null : words.join(',');
}

/// `uptime:`/`lifetime:` as seconds. The spec asks for `26h`, not `94340s`
/// (10.5), so every reader that wants a number parses the same shorthand here.
int xprsUptimeSeconds(String? v) {
  if (v == null || v.isEmpty) return 0;
  final m = RegExp(r'^(\d+)\s*([a-z]*)$').firstMatch(v.trim().toLowerCase());
  if (m == null) return 0;
  final n = int.tryParse(m.group(1)!) ?? 0;
  return switch (m.group(2)) {
    'day' || 'days' || 'd' => n * 86400,
    'hour' || 'hours' || 'h' => n * 3600,
    'min' || 'mins' || 'm' => n * 60,
    _ => n,
  };
}

/// Does this station look like one worth leaning on (12.9.4)?
///
/// Never a word on the wire. [named] is what the operator wrote down, which
/// needs no inference; everything else is judged by the qualities: it offers
/// the archive role, it is addressable off-radio, and it is either deep
/// (`count:`, 13.0.1 — records held, not callsigns heard) or long awake.
bool xprsLooksAlwaysOn({
  required String callsign,
  required List<String> services,
  required String bearer,
  required int count,
  required int uptimeSeconds,
  required Set<String> named,
}) {
  if (named.contains(callsign.trim().toUpperCase())) return true;
  if (!services.contains('archive')) return false;
  // Addressable: reachable other than by standing next to it.
  if (bearer != 'rns' && bearer != 'lan') return false;
  return count >= 10000 || uptimeSeconds >= 7 * 24 * 3600;
}

/// What this station keeps and for whom, as the Archiver screen reads it.
///
/// One place assembles it so the screen cannot drift from the rule: every
/// number here comes from the archive, the history server or the preferences,
/// and none of it is computed twice. Called when the screen refreshes — the
/// archive fires `core.archive` at most once per flush — never per packet.
Map<String, dynamic> xprsArchiveStatusJson({
  required bool public,
  required bool alwaysOn,
  required bool alwaysOnStored,
  required bool keepFollowed,
  required bool keepChatter,
  required int quotaMb,
  required int maxDays,
  required ({int own, int followed, int stranger, int total}) records,
  required int bytes,
  required int followedCallsigns,
  required int asksLastHour,
  required int answered,
  required int refused,
  required String announced,
  required List<String> named,
}) {
  String human(int b) {
    if (b >= 1024 * 1024 * 1024) {
      return '${(b / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
    }
    if (b >= 1024 * 1024) return '${(b / (1024 * 1024)).toStringAsFixed(1)} MB';
    if (b >= 1024) return '${(b / 1024).round()} kB';
    return '$b B';
  }

  final quotaBytes = quotaMb * 1024 * 1024;
  return {
    'public': public,
    'alwaysOn': alwaysOn,
    'alwaysOnStored': alwaysOnStored,
    'keepFollowed': keepFollowed,
    'keepChatter': keepChatter,
    'quotaMb': quotaMb,
    'maxDays': maxDays,
    'records': {
      'own': records.own,
      'followed': records.followed,
      'stranger': records.stranger,
      'total': records.total,
    },
    'bytes': bytes,
    'bytesText': human(bytes),
    'quotaText': human(quotaBytes),
    // How full the STRANGERS' shelf is against its limit — the only part of
    // the spool the quota bounds.
    'fullFrac': quotaBytes <= 0
        ? 0.0
        : (bytes / quotaBytes).clamp(0.0, 1.0).toDouble(),
    'followedCallsigns': followedCallsigns,
    'asksLastHour': asksLastHour,
    'answered': answered,
    'refused': refused,
    // What the beacon actually claims, so the screen never has to guess.
    'announced': announced,
    'named': named,
  };
}
