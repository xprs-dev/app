/// The XPRS vocabularies a transport has to understand.
///
/// Deliberately not all of them. Most of the format is content — `mood:`,
/// `kind:` on a place, the poll options — and a transport has no business
/// knowing those. What is here is what decides how bytes travel: how urgent a
/// packet is, how far it may be relayed, and where it may go.
library;

import 'dart:convert';

import 'xprs_packet.dart';

/// How much a carried packet is worth keeping when the store is full
/// (`docs/XPRS.md` section 13.5).
///
/// Ordered lowest-first: the custody store evicts `ORDER BY urg, ts`.
enum XprsUrgency {
  low,
  normal,
  high,
  urgent;

  /// Parse an `urg:` value. Anything unrecognised is [normal], because design
  /// rule 8 skips an unknown word rather than failing, and dropping a message
  /// whose urgency did not parse would be worse than carrying it.
  static XprsUrgency fromWire(String? v) =>
      switch (v?.trim().toLowerCase()) {
        'low' => XprsUrgency.low,
        'high' => XprsUrgency.high,
        'urgent' => XprsUrgency.urgent,
        _ => XprsUrgency.normal,
      };

  /// The highest level this may be raised to. A sender states what it wants;
  /// the carrier decides what it is allowed to have (section 13.5).
  XprsUrgency cappedAt(XprsUrgency cap) => index <= cap.index ? this : cap;
}

/// How far a packet may be relayed, by packet type (`docs/XPRS.md` section 13.1).
///
/// The limit belongs to the type rather than to a field, so a sender cannot ask
/// the network for more airtime than its traffic warrants, and an emergency does
/// not have to remember to ask.
int xprsRelayLimit(String type) =>
    (type == 'sos' || type == 'warning') ? 9 : 3;

/// The callsigns that have relayed a packet, oldest first (section 13).
///
/// The hop count is not transmitted: it is the length of this list.
List<String> xprsVia(XprsPacket p) {
  final v = p['via'];
  if (v == null || v.isEmpty) return const [];
  return v.split(',').where((c) => c.isNotEmpty).toList();
}

/// Whether [p] may still be relayed, given its type and the hops it has taken.
bool xprsMayRelay(XprsPacket p) =>
    xprsVia(p).length < xprsRelayLimit(p.type);

/// Whether [self] already appears in `via:` (section 13.2).
///
/// A station that finds itself in the path does not relay, whatever the count
/// says: the limit bounds how far a packet travels, the path stops it going in
/// a circle, and neither substitutes for the other.
bool xprsWouldLoop(XprsPacket p, String self) {
  final me = self.toUpperCase();
  return xprsVia(p).any((c) => c.toUpperCase() == me);
}

/// Does this packet carry something a PERSON should be shown?
///
/// The mesh is mostly machines talking: on a four-station bench, 176
/// observations and 105 catch-up commands against 15 messages. All of it must
/// cross the air freely — that is what a mesh is — and almost none of it
/// belongs on a screen. A `cmd:history` ask, a `t:result`, a receipt, an
/// identity or an observation is housekeeping, and rendering it as
/// correspondence buries the correspondence.
///
/// `t:message` is the set, and it is not a new judgement: the custody
/// acceptance rule already says the same thing in the same words — *"Only a
/// 1:1 message is custody material … an observation, a status or a poll is
/// aired, not couriered"*.
///
/// Deliberately NOT `sos` and `warning`, though a person certainly wants
/// those: section 13.1 gives them nine relays so they are **aired**, and they
/// reach people by being heard rather than by being couriered into an inbox.
bool xprsRendersToPerson(XprsPacket p) => p.type == 'message';

/// Every packet type the specification defines (section 4.2).
///
/// The list is CLOSED -- "An unknown type is ignored. It is never an error and
/// is never displayed as a message." That sentence is the whole reason this set
/// exists here rather than as a loose string test.
const Set<String> kXprsTypes = {
  'message', 'observation', 'receipt', 'reaction', 'request', 'identity',
  'track', 'sos', 'info', 'blog', 'poll', 'file', 'report', 'place', 'status',
  'passage', 'event', 'offer', 'need', 'channel', 'mailbox', 'service',
  'command', 'result', 'moderate', 'challenge', 'response', 'warning',
  'ping', 'pong',
};

/// Is [content] an XPRS protocol wire rather than something a person wrote?
///
/// THE POINT: protocol must never reach a screen. Two places used to decide
/// this with `content.startsWith('t:')` -- `RnsService`'s inbound LXMF handler
/// and the chat wapp's `lxmf_drain` -- and both were wrong in the same way. A
/// wire whose first field is not `t:` (observed on the bench:
/// `x:<sealed> t:message f:X3ARK d:X1VCVM ts:... n:2/3 sig:...`) failed both
/// tests, was filed in the LXMF inbox as ordinary correspondence, and arrived
/// as a chat bubble and an Android notification. Hundreds of them.
///
/// So this asks the honest question instead of the convenient one: is the text
/// SHAPED like a packet, wherever its fields happen to sit. A wire always
/// carries a type from the closed vocabulary and the callsign that sent it, so
/// `t:<known-type>` plus `f:` is the test. `m:` is deliberately not required --
/// a sealed packet replaces it with `x:` (section 9.2).
///
/// Ordinary writing does not collide with this. A colon in prose ("meet me at
/// 5: the pub") is not a `t:` token, and a person would have to type both a
/// real type word and an `f:` callsign to be mistaken for a packet.
///
/// Cost: one pass over a string already in memory, no regex, and at most two
/// short substrings allocated (docs/performance.md section 4.2 -- a cheap call
/// in a hot loop IS the drain, and this one runs per inbound message).
/// A wire whose fields are in an order `XprsPacket.parse` will accept, or null
/// when [content] is not a wire at all.
///
/// Section 4 puts `t:` first and every parser in the tree assumes it
/// (`XprsPacket.parse` returns null otherwise). Wires reach us that do not:
/// measured on the bench, a carried packet arrived as
/// `x:<sealed> t:message f:X3ARK d:X1VCVM ts:... n:4/4 sig:...`. Design rule 8
/// says a receiver is tolerant of what it is given, and the alternative here is
/// worse than tolerance -- an unparseable wire was shown to the user AS the
/// message, which is the bug this exists to end.
///
/// Rotating rather than reordering: the fields keep their relative order and
/// only the leading run moves to the back, so nothing is invented and the
/// packet still carries exactly the fields it arrived with.
String? xprsNormaliseWire(String content) {
  if (!xprsLooksLikeWire(content)) return null;
  if (content.startsWith('t:')) return content;
  final at = content.indexOf(' t:');
  if (at < 0) return null;
  return '${content.substring(at + 1)} ${content.substring(0, at)}';
}

bool xprsLooksLikeWire(String content) {
  if (content.length < 4) return false;
  var sawType = false;
  var sawFrom = false;
  var i = 0;
  while (i < content.length) {
    var end = content.indexOf(' ', i);
    if (end < 0) end = content.length;
    // A field is `key:value`; only two keys interest us, so test the key's
    // bytes in place and skip everything else without building a string.
    if (end - i > 2 && content.codeUnitAt(i + 1) == 0x3a /* ':' */) {
      final k = content.codeUnitAt(i);
      if (!sawType && k == 0x74 /* t */) {
        sawType = kXprsTypes.contains(content.substring(i + 2, end));
      } else if (!sawFrom && k == 0x66 /* f */) {
        sawFrom = true;
      }
      if (sawType && sawFrom) return true;
    }
    i = end + 1;
  }
  return false;
}

/// The relays the SENDER asked for, in order (section 13.2.2).
///
/// Three fields hold a list of callsigns and they are not the same field:
/// `relay:` is the route asked for and only the author writes it, `via:` is
/// the route taken and every relay appends to it, `route:` (section 13.10) is
/// the route taken as the recipient attested it inside a signature. Asked,
/// happened, attested.
List<String> xprsRelay(XprsPacket p) {
  final v = p['relay'];
  if (v == null || v.isEmpty) return const [];
  return v.split(',').where((c) => c.trim().isNotEmpty).toList();
}

/// The next station [p] asks to relay it, or null when it names none or the
/// list is spent.
///
/// Section 13.2.2: *"The next hop is the first callsign in `relay:` that does
/// not appear in `via:`."* Nothing is consumed and nothing is rewritten —
/// `relay:` is inside the signature and the section 5 identifier, so editing
/// it would change the packet's identity at every hop. `via:` is what
/// advances.
String? xprsRelayNext(XprsPacket p) {
  final asked = xprsRelay(p);
  if (asked.isEmpty) return null;
  final taken = xprsVia(p).map((c) => c.trim().toUpperCase()).toSet();
  for (final hop in asked) {
    final h = hop.trim().toUpperCase();
    if (!taken.contains(h)) return h;
  }
  return null; // spent: nobody relays
}

/// Whether [self] is the hop [p] asks for next (section 13.2.2).
///
/// Compared whole and case-insensitively, **suffix included** — `X3ARK-9` is a
/// different device from `X3ARK` (section 3.1), and a sender that writes one
/// meaning the other has named a station that will never answer.
bool xprsRelayNextIs(XprsPacket p, String self) {
  final next = xprsRelayNext(p);
  return next != null && next == self.trim().toUpperCase();
}

/// [p] with [self] appended to `via:`, which is what a relay transmits.
///
/// Neither the identifier nor the signature changes, because both are computed
/// with `via:` removed (sections 5 and 9.1).
XprsPacket xprsAppendVia(XprsPacket p, String self) {
  final path = xprsVia(p);
  return p.with_('via', [...path, self.toUpperCase()].join(','));
}

/// How far a packet may travel, geographically and by network
/// (`docs/XPRS.md` section 13.11).
enum XprsScope {
  /// Anywhere, including the internet. The default when `scope:` is absent.
  global,

  /// Only the bearers in range now — Bluetooth, WiFi Direct, WiFi Aware, a LAN.
  /// Never carried, never gatewayed.
  local,

  /// One or more ISO 3166-1 alpha-2 country codes.
  country,
}

/// The scope of [p], and the country codes when it names any.
({XprsScope scope, List<String> countries}) xprsScope(XprsPacket p) {
  final v = p['scope'];
  if (v == null || v.isEmpty || v == 'global') {
    return (scope: XprsScope.global, countries: const []);
  }
  if (v == 'local') return (scope: XprsScope.local, countries: const []);
  return (
    scope: XprsScope.country,
    countries: v.split(',').where((c) => c.isNotEmpty).toList()
  );
}

/// Whether [p] may be handed to a carrier at all (section 13.11.3).
///
/// A `local` packet is for the bearers in range now, so carrying it to another
/// town is precisely what it excludes — and the refusal belongs at admission,
/// not at transmission, or a parked copy leaks later.
bool xprsMayCarry(XprsPacket p) => xprsScope(p).scope != XprsScope.local;

/// The bearer a reading is about (`docs/XPRS.md` section 10.6.1).
///
/// Required on any packet carrying `busy:`, `txtime:` or `hears:`, because a
/// station here is not one radio on one channel and a figure averaged across
/// LoRa and a LAN is not a quantity.
const Set<String> kXprsBearers = {
  'lora',
  'ble',
  'wifi',
  'espnow',
  'halow',
  'lan',
  'internet',
  'vhf',
  'uhf',
  'hf',
  'cb',
  'pmr',
  'satellite',
  'other',
};

/// What a station says it does for other stations (`docs/XPRS.md` section 24,
/// `serve:`). A fixed set: a word outside it is dropped rather than shown,
/// because `serve:` is read to decide who to ask for something, and a made-up
/// word would be a promise nobody defined.
const Set<String> kXprsServices = {
  'relay',
  'archive',
  // The archive role at server scale (36.9.4), announced BESIDE `archive` and
  // never instead of it. It was missing here while this very device airs it on
  // both beacons (mesh_service.dart), so our own receiver dropped a word our
  // own transmitter sent -- and everything downstream that asked "is this a
  // super-archiver" was reading a list that could never say yes.
  'super',
  'internet',
  'aprs',
  'nostr',
  'files',
  'devices',
  'time',
  'weather',
  'wifi',
  'other',
};

/// The measurement keys a station may report about itself or its surroundings
/// (`docs/XPRS.md` sections 10.4 and 23.3, listed together at section 9.2.1).
/// Values are kept as the TEXT that was sent: the unit is part of the value
/// (section 4.4), so `temp:14.2C` is shown as "14.2C" and never turned into a
/// bare number that has lost what it measured.
///
/// There is deliberately no storage or disk key here, because the format has
/// none. An archiver says how much it holds with `count:` (section 36.9) and
/// how much mail is waiting with `mail:`, and those are the honest answers to
/// "how full is it".
const Set<String> kXprsReadings = {
  // weather
  'temp', 'hum', 'press', 'wind', 'wdir', 'intemp', 'inhum',
  'rain1', 'rain24',
  // telemetry
  'batt', 'dose', 'lifedose', 'radon', 'rf', 'efield', 'mfield', 'odometer',
  // what keeps it running (section 23.3)
  'supply',
};

/// The `serve:` list of a packet, filtered to the words section 24 defines.
/// Empty when the packet claims nothing.
List<String> xprsServices(XprsPacket p) {
  final raw = p['serve'];
  if (raw == null || raw.isEmpty) return const [];
  final out = <String>[];
  for (final w in raw.split(',')) {
    final s = w.trim().toLowerCase();
    if (s.isNotEmpty && kXprsServices.contains(s) && !out.contains(s)) {
      out.add(s);
    }
  }
  return out;
}

/// The callsigns a station says it hears directly (section 10.6.3). Empty when
/// it says none — which is not the same as `peers:0`, and the caller keeps the
/// distinction.
List<String> xprsHears(XprsPacket p) {
  final raw = p['hears'];
  if (raw == null || raw.isEmpty) return const [];
  final out = <String>[];
  for (final c in raw.split(',')) {
    final s = c.trim().toUpperCase();
    if (s.isNotEmpty && !out.contains(s)) out.add(s);
  }
  return out;
}

/// Build the neighbour half of a discovery beacon (`docs/XPRS.md` section
/// 10.6.4).
///
/// [candidates] must already be ordered most-relevant-first — the format leaves
/// what "relevant" means to the sender, so the caller decides whether that is
/// signal now, uptime, or being a powered relay on a hill.
///
/// Returns `hears:` truncated to whatever fits [budget] and `peers:` set to the
/// **full** count, which is the point: without it a short list cannot be told
/// from a small mesh, and a client would draw a map that is quietly wrong.
({int peers, List<String> hears}) xprsNeighbourFit(
  List<String> candidates,
  XprsPacket envelope,
  int budget,
) {
  final total = candidates.length;
  var take = <String>[];
  for (var i = 1; i <= candidates.length; i++) {
    final trial = candidates.sublist(0, i);
    final p = envelope
        .with_('peers', '$total')
        .with_('hears', trial.join(','));
    if (utf8.encode(p.encode()).length > budget) break;
    take = trial;
  }
  return (peers: total, hears: take);
}

/// How many stations the sender can reach directly, of which `hears:` lists the
/// ones that fitted (section 10.6.4). Null when the packet states none.
int? xprsPeers(XprsPacket p) => int.tryParse(p['peers'] ?? '');

/// A duration as an XPRS `qty` (section 10.9: `s`, `min`, `h`, `day`) — coarse
/// on purpose. `uptime:` and `lifetime:` (section 10.5) change by the second
/// while their meaning changes by the hour, so the spec asks for `uptime:26h`,
/// not `uptime:94340s`.
String xprsFmtDuration(int seconds) {
  if (seconds < 120) return '${seconds}s';
  if (seconds < 120 * 60) return '${seconds ~/ 60}min';
  if (seconds < 48 * 3600) return '${seconds ~/ 3600}h';
  return '${seconds ~/ 86400}day';
}

/// An XPRS `ts:` (`YYYY-MM-DD_hh:mm:ss`, UTC — section 4.8) as epoch
/// milliseconds, or null when it does not parse. One implementation, because
/// the archive orders by it, `cmd:history` windows on it, and a mailbox
/// declaration's `since:`/`until:` bound with it — and three parsers of one
/// format is how they disagree.
/// Format [epochMs] as the `ts:` of section 4: `YYYY-MM-DD_HH:MM:SS`, UTC.
///
/// The inverse of [xprsParseTs]. Defaults to now, which is what almost every
/// caller wants when it is building a packet.
String xprsNowTs([int? epochMs]) {
  final d = DateTime.fromMillisecondsSinceEpoch(
      epochMs ?? DateTime.now().millisecondsSinceEpoch,
      isUtc: true);
  String two(int n) => n.toString().padLeft(2, '0');
  return '${d.year}-${two(d.month)}-${two(d.day)}_'
      '${two(d.hour)}:${two(d.minute)}:${two(d.second)}';
}

int? xprsParseTs(String? v) {
  if (v == null || v.length != 19 || v[10] != '_') return null;
  final t = DateTime.tryParse('${v.substring(0, 10)}T${v.substring(11)}Z');
  return t?.millisecondsSinceEpoch;
}

/// Messages this station holds for others and would hand over (section 10.6.5).
///
/// Deliberately not part of [xprsReadingIsScoped]: mail held is a fact about the
/// station, not about one bearer, so it needs no `link:`.
int? xprsMail(XprsPacket p) => int.tryParse(p['mail'] ?? '');

/// Whether a channel reading on [p] is usable: it must name its bearer.
///
/// A reading without `link:` is discarded rather than guessed at — it is not
/// vague, it is unanswerable.
bool xprsReadingIsScoped(XprsPacket p) {
  final hasReading = p.has('busy') || p.has('txtime') || p.has('hears');
  if (!hasReading) return true;
  final link = p['link'];
  return link != null && kXprsBearers.contains(link);
}
