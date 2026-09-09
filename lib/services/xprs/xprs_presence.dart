/*
 * xprs_presence — is this an XPRS device, who is it, and can we reach it?
 *
 * One question, asked in three places, answered three different ways. That is
 * the whole defect this file exists to end:
 *
 *   the live graph    services.any((s) => !{lxmf, lxmf-prop, node}.contains(s))
 *   the stored count  services.any((s) => s != 'lxmf' && s != 'lxmf-prop')
 *   the header badge  callsign.startsWith('X1' / 'X2' / 'X3')
 *
 * The first two differ by one word, which is why one screen said 715 XPRS
 * devices and the network had six. None of the three required a CALLSIGN, so a
 * Reticulum destination that merely announced on a hash we associate with an
 * XPRS service was counted as a device, listed as a person, and given a
 * Follow/Chat button that could never work.
 *
 * The rule here is the opposite way round: **a device is XPRS if we can name
 * it with a callsign we are entitled to believe.** Services are a property of
 * a device already identified; they never identify one.
 *
 * Pure on purpose (docs/architecture.md §3: the core owns the verdict, and a
 * verdict that cannot be tested is a guess). No services, no singletons, no
 * Flutter: inputs in, one record out, so the whole table is a unit test.
 */
library;

import '../../util/nostr_crypto.dart';

/// What the callsign says this device is (XPRS.md 3.1).
enum XprsKind {
  /// `X1` — a person.
  user,

  /// `X2` movable (a ship, a car), `X3` fixed (a relay, a mast).
  station,

  /// `X4` — automated equipment. Shown with the stations; it is not a person.
  device,
}

/// WHY we believe the callsign, strongest first. Kept on the verdict because
/// "heard on BLE two minutes ago" and "claimed it in an announce" are
/// different degrees of knowledge, and the panel should be able to say which.
enum XprsEvidence {
  /// A parsed XPRS wire arrived on a radio/LAN bearer. Nothing is stronger:
  /// only such a packet can create a station in [XprsMonitor].
  air,

  /// A parsed XPRS wire arrived over Reticulum. Same trust as [air]; the
  /// bearer differs, not the proof.
  remoteWire,

  /// The station stated its callsign and its Reticulum destination in one
  /// signed beacon, so the pairing costs nothing and cannot be mistaken.
  beaconPairing,

  /// An announce carried a name, and the key it was announced with could have
  /// produced that name (`NostrCrypto.callsignMatchesKey`).
  announceVerified,

  /// An announce on an XPRS service aspect carried a callsign-shaped name, but
  /// no key was present to check it against. Believed, and marked weakest.
  announceClaimed,
}

/// One device's facts, gathered from wherever they live. Deliberately plain:
/// the caller does the gathering, this file does the deciding.
class XprsCandidate {
  const XprsCandidate({
    this.announcedCallsign = '',
    this.pairedCallsign = '',
    this.derivedCallsign = '',
    this.nostrPubHex = '',
    this.identityHex = '',
    this.heardOnAir = false,
    this.heardOverRns = false,
    this.services = const {},
    this.airBearers = const [],
    this.announceBearer = '',
    this.rnsPathHeld = false,
    this.announceFresh = false,
    this.reachableOnAir = false,
    this.firstSeenMs = 0,
    this.lastSeenMs = 0,
  });

  /// The name an announce carried (`callsign`, else the LXMF display name).
  final String announcedCallsign;

  /// A callsign learned from a beacon that also gave its Reticulum address.
  final String pairedCallsign;

  /// The callsign this node's own key produces. Not a claim at all — the name
  /// IS the key, so a device that announced an XPRS service and a key can be
  /// named even when it announced no text (which is how most of them arrive).
  final String derivedCallsign;

  /// The key the announce was made with, when one was carried.
  final String nostrPubHex;
  final String identityHex;

  /// An XPRS wire from this station reached us on a radio/LAN bearer.
  final bool heardOnAir;

  /// An XPRS wire from this station reached us over Reticulum.
  final bool heardOverRns;

  final Set<String> services;

  /// Bearers the station is on, as [XprsMonitor] judges them.
  final List<String> airBearers;

  /// The bearer an announce arrived over, already reduced to a word
  /// (`lan` for two devices on one LAN, `rns` for something that crossed the
  /// internet).
  final String announceBearer;

  /// A Reticulum path to this callsign is held right now.
  final bool rnsPathHeld;

  /// The announce is inside the freshness window.
  final bool announceFresh;

  /// Heard on a radio/LAN bearer inside the freshness window.
  final bool reachableOnAir;

  final int firstSeenMs;
  final int lastSeenMs;
}

/// The verdict. Absent (`null` from [classifyXprs]) means "not an XPRS device",
/// which is the answer for every Reticulum node we cannot name.
class XprsDevice {
  const XprsDevice({
    required this.callsign,
    required this.kind,
    required this.fixed,
    required this.evidence,
    required this.bearers,
    required this.reachable,
    required this.services,
    this.identityHex = '',
    this.npub = '',
    this.firstSeenMs = 0,
    this.lastSeenMs = 0,
  });

  /// Bare and uppercase — the identity every surface keys on, so one operator
  /// reachable two ways is one device rather than two rows.
  final String callsign;
  final XprsKind kind;

  /// `X3` rather than `X2`. Only meaningful for [XprsKind.station].
  final bool fixed;
  final XprsEvidence evidence;

  /// Every way this device can be reached now: `ble`, `lan`, `espnow`, `wifi`,
  /// `lora`, `vhf`/`uhf`/`hf`, and `rns` for Reticulum.
  final List<String> bearers;
  final bool reachable;
  final List<String> services;
  final String identityHex;
  final String npub;
  final int firstSeenMs;
  final int lastSeenMs;

  String get kindWord => switch (kind) {
        XprsKind.user => 'user',
        XprsKind.station => 'station',
        XprsKind.device => 'device',
      };
}

/// The services that only an XPRS station announces. A node carrying one of
/// these is running our software — which still does not tell us WHO it is, and
/// so is not on its own enough to count it (see the file header).
const Set<String> kXprsServiceAspects = {
  'chat',
  'files',
  'dht',
  'wapp',
  'relay',
};

/// A callsign this format could have issued: `X1`–`X5` plus 2–5 characters, or
/// an amateur licence. Deliberately the shape only — whether the holder is
/// entitled to it is [NostrCrypto.callsignMatchesKey]'s question.
final RegExp _shaped =
    RegExp(r'^(X[1-5][A-Z0-9]{2,5}|[A-Z0-9]{1,3}[0-9][A-Z0-9]*)(-[0-9]{1,2})?$');

/// Decide what [s] is. Returns null when it is not an XPRS device: a hub, a
/// group address, an LXMF or NomadNet node, or anything we cannot name.
XprsDevice? classifyXprs(XprsCandidate s) {
  final named = _name(s);
  if (named == null) return null;
  final (call, evidence) = named;

  // A group is an address several stations read (XPRS.md 6.3), not a device.
  if (call.startsWith('X5')) return null;

  final XprsKind kind;
  var fixed = false;
  if (call.startsWith('X1')) {
    kind = XprsKind.user;
  } else if (call.startsWith('X2')) {
    kind = XprsKind.station;
  } else if (call.startsWith('X3')) {
    kind = XprsKind.station;
    fixed = true;
  } else if (call.startsWith('X4')) {
    kind = XprsKind.device;
  } else {
    // A licensed callsign. Nothing in it says movable or fixed, and guessing
    // would be worse than saying station.
    kind = XprsKind.station;
  }

  final bearers = <String>[];
  for (final b in s.airBearers) {
    final w = b.trim().toLowerCase();
    if (w.isNotEmpty && !bearers.contains(w)) bearers.add(w);
  }
  final ann = s.announceBearer.trim().toLowerCase();
  if (ann.isNotEmpty && ann != 'rns' && !bearers.contains(ann)) {
    bearers.add(ann);
  }
  // Reticulum last: it is the lane that is always there when it is there at
  // all, and a reader scanning the row wants the radio first.
  final onRns = s.rnsPathHeld || s.heardOverRns || ann == 'rns';
  if (onRns && !bearers.contains('rns')) bearers.add('rns');

  return XprsDevice(
    callsign: call,
    kind: kind,
    fixed: fixed,
    evidence: evidence,
    bearers: bearers,
    reachable: s.reachableOnAir || s.rnsPathHeld || s.heardOverRns ||
        (s.announceFresh && bearers.isNotEmpty),
    services: (s.services.toList()..sort()),
    identityHex: s.identityHex,
    npub: s.nostrPubHex,
    firstSeenMs: s.firstSeenMs,
    lastSeenMs: s.lastSeenMs,
  );
}

/// The callsign we are entitled to believe, and why. Null when there is none.
(String, XprsEvidence)? _name(XprsCandidate s) {
  final announced = NostrCrypto.bareCallsign(s.announcedCallsign).toUpperCase();
  final paired = NostrCrypto.bareCallsign(s.pairedCallsign).toUpperCase();

  // 1 & 2. An XPRS wire named it. Only a parsed packet with an `f:` field can
  // put a callsign here, so it is evidence by construction and needs no key —
  // most stations on a radio have no key we hold, and requiring one would
  // empty the map on a LoRa-only site.
  if (s.heardOnAir && announced.isNotEmpty) {
    return (announced, XprsEvidence.air);
  }
  if (s.heardOverRns && announced.isNotEmpty) {
    return (announced, XprsEvidence.remoteWire);
  }
  // 3. The station stated its callsign and its Reticulum address together.
  if (paired.isNotEmpty && _shaped.hasMatch(paired)) {
    return (paired, XprsEvidence.beaconPairing);
  }
  // 4. The key could have produced the name.
  if (announced.isNotEmpty &&
      _shaped.hasMatch(announced) &&
      s.nostrPubHex.isNotEmpty &&
      NostrCrypto.callsignMatchesKey(announced, s.nostrPubHex)) {
    return (announced, XprsEvidence.announceVerified);
  }
  // 4b. It announced no name we can use, but it announced OUR service with a
  // key, and a key produces exactly one name. Nothing is claimed here.
  final derived = NostrCrypto.bareCallsign(s.derivedCallsign).toUpperCase();
  if (derived.isNotEmpty &&
      _shaped.hasMatch(derived) &&
      s.services.any(kXprsServiceAspects.contains)) {
    return (derived, XprsEvidence.announceVerified);
  }
  // 5. No key to check, but the name came in on an XPRS service aspect and is
  // callsign-shaped. Weakest, and still a name.
  if (announced.isNotEmpty &&
      _shaped.hasMatch(announced) &&
      s.nostrPubHex.isEmpty &&
      s.services.any(kXprsServiceAspects.contains)) {
    return (announced, XprsEvidence.announceClaimed);
  }
  // A name that does not match the key that announced it is not this device's
  // name, whatever else it is.
  return null;
}
