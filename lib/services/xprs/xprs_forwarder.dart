/*
 * xprs_forwarder — mail migrates toward the recipient (XPRS.md 12.8.1).
 *
 * A station holding mail for X that it cannot deliver hands the held wire —
 * as CUSTODY, the author's signature intact — toward where X actually is:
 * X's own declared mailboxes first (9.12, consulted in its order), then EVERY
 * gateway whose live sighting of X is fresh (12.9.4's L3), and only when both
 * are empty the place X was last seen (L2). Each gateway is its own custody
 * trail: our callsign joins `via:` once, and the one receipt X signs releases
 * every holder that hears it (9.7.1), so several copies out cost nothing but
 * the sends and buy delivery by whichever gateway actually meets X.
 *
 * Two rules keep it from being a flood:
 *
 *   - once per (packet, gateway): a re-heard copy does not go around again,
 *     but a gateway that reports X LATER still gets its copy (retry);
 *   - a holder that can reach X itself forwards nothing: it is the gateway,
 *     and 12.8.1's release-on-hearing delivers. Without this a gateway
 *     receiving the forwarded copy over the internet asked an always-on
 *     archiver where X was while X was beaconing at it.
 *
 * The sends are injected, so the whole decision runs in the simulation
 * (test/support/mail_relay_sim.dart) with no radio. The default lane is
 * directed Reticulum where the gateway resolves; the radio custody lanes keep
 * doing what they always did for gateways in radio reach.
 */
import 'dart:convert';
import 'dart:typed_data';

import '../log_service.dart';
import '../preferences_service.dart';
import '../reticulum/rns_service.dart';
import 'xprs_archive.dart';
import 'xprs_gossip.dart';
import 'xprs_id.dart';
import 'xprs_mailbox.dart';
import 'xprs_packet.dart';
import 'xprs_publisher.dart';
import 'xprs_vocab.dart';

class XprsForwarder {
  XprsForwarder._();
  static final XprsForwarder instance = XprsForwarder._();

  /// How many gateways one packet is handed to at most: 12.9.4's G, the
  /// number of live sightings gossip keeps per callsign.
  static const int maxGateways = XprsGossip.liveCapG;

  int forwarded = 0, noRoute = 0, loops = 0, selfDelivers = 0, retries = 0;

  // ── injected by the core (mesh_service); the defaults are the device ──────

  /// Send one wire to one callsign over the directed lane, or false when
  /// there is none right now. The default: LXMF when the network can name
  /// the gateway, else a verbatim re-air on every bearer (an ESP32 gateway
  /// has no letterbox; it hears the re-air like any packet and holds it as
  /// the mail it is).
  Future<bool> Function(String call, String wire)? sendTo;

  /// Can THIS station deliver to [call] itself? The mailbox's own test
  /// (a Reticulum path, or heard directly in the last ten minutes).
  bool Function(String call)? canDeliver;

  /// X's declared mailboxes (L1), freshest declaration, in its order.
  List<String> Function(String call)? holdersOf;

  /// Where X was seen (L3 live, then L2 visits), freshest first.
  List<GossipSighting> Function(String call)? sightingsOf;

  /// The always-on archivers this station names, for the miss path.
  List<String> Function()? namedArchivers;

  /// Every wire this station holds for [call], backoff or not: a new gateway
  /// is a new place to send, whatever the radio re-air ladder says.
  List<String> Function(String call)? heldFor;

  /// One forward per (packet, gateway). Bounded; a restart forgets, which is
  /// the right trade (a duplicate forward is airtime; a burnt hop is a
  /// delivery).
  final Map<String, int> _sent = {};
  static const int _sentMax = 1024;

  /// Try to move one held wire toward where [target] is. Returns the gateways
  /// it went to; empty when it stayed here (we can deliver it ourselves, no
  /// route, a loop, or no lane).
  Future<List<String>> maybeForward(String target, String wire,
      {required String selfBase}) async {
    final p = XprsPacket.parse(wire);
    if (p == null) return const [];
    final self = selfBase.trim().toUpperCase();
    final to = target.trim().toUpperCase();
    // Only a station's mail is forwarded toward a mailbox. A group has none:
    // asking an always-on archiver "where is X5A3F2" spends airtime on a
    // question with no answer, depositing a group post as somebody's mail is
    // the wrong shelf, and the fallback re-airs it with our callsign appended
    // to `via:` -- one of 9.1's three hops spent on traffic that is aired, not
    // couriered (docs/store-and-forward.md: groups are never carried).
    if (!xprsAddressesStation(to)) return const [];

    final via = xprsVia(p).map((c) => c.trim().toUpperCase()).toSet();
    if (via.contains(self)) {
      loops++;
      return const []; // it already passed through us once (9.2)
    }
    // An author is not one of its own relays (9: `via:` is "the list of
    // callsigns that RELAYED the packet"). maybeForward is called on our own
    // freshly authored wire the moment /api/xprs/send accepts it, so without
    // this the first directed message a station sends leaves carrying its own
    // callsign in `via:`.
    if ((p['f'] ?? '').trim().toUpperCase() == self) return const [];

    // We ARE the gateway: 12.8.1's release-on-hearing (or the mailbox sweep)
    // delivers, and forwarding would hand our neighbour's mail to somebody
    // further away.
    if (_canDeliver(to)) {
      selfDelivers++;
      return const [];
    }

    final id = xprsIdentifier(p);
    final gateways = _gatewaysFor(to, self: self, via: via);
    if (gateways.isEmpty) {
      // Gossip knows nothing: ask an always-on archiver (the answer feeds
      // the next attempt, and Part 3's retry acts on it), and meanwhile
      // DEPOSIT the mail with one -- 12.12 step 1, "hand it to any archiver"
      // -- rather than sitting on it.
      final named = _named();
      XprsGossip.instance.askAlwaysOn(to,
          publish: (w) async =>
              XprsPublisher.instance.publishWire(w, slot: 'ask:$to'),
          alwaysOnArchivers: named,
          selfBase: self);
      for (final sa in named) {
        final g = sa.trim().toUpperCase();
        if (g.isEmpty || g == self || g == to || via.contains(g)) continue;
        gateways.add(g);
        break;
      }
    }
    if (gateways.isEmpty) {
      noRoute++;
      return const [];
    }

    // 12.8.1: "the section 9.1 budget and the 9.2 loop check apply". The
    // loop half was checked above; the budget is `xprsMayRelay`.
    if (!xprsMayRelay(p)) {
      loops++;
      return const [];
    }
    final carried = xprsAppendVia(p, self);
    if (!carried.fits) return const []; // a via: that no longer fits stays put
    final wire2 = carried.encode();

    final went = <String>[];
    for (final gateway in gateways) {
      final key = '$id|$gateway';
      if (_sent.containsKey(key)) continue;
      _remember(key);
      final ok = await _send(gateway, wire2, id: id);
      if (ok) {
        forwarded++;
        went.add(gateway);
      }
      LogService.instance.add('XPRS: held mail for $to forwarded toward '
          '$gateway (${ok ? "carried" : "kept"}) — 12.8.1');
    }
    return went;
  }

  /// Somebody just reported hearing [target] (XprsGossip.onSighting): run
  /// everything held for it through [maybeForward] again. The per-(packet,
  /// gateway) memory means only the NEW reporter gets a copy; the throttle
  /// means a burst of reports costs one pass. Returns how many wires moved.
  final Map<String, int> _retriedMs = {};
  static const int retryEveryMs = 30000;

  Future<int> retry(String target, {required String selfBase, int? nowMs}) async {
    final to = target.trim().toUpperCase();
    if (to.isEmpty) return 0;
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    if (now - (_retriedMs[to] ?? 0) < retryEveryMs) return 0;
    _retriedMs[to] = now;
    if (_retriedMs.length > 256) _retriedMs.remove(_retriedMs.keys.first);
    final wires = heldFor?.call(to) ?? const <String>[];
    if (wires.isEmpty) return 0;
    retries++;
    var moved = 0;
    for (final w in wires) {
      if ((await maybeForward(to, w, selfBase: selfBase)).isNotEmpty) moved++;
    }
    if (moved > 0) {
      LogService.instance.add(
          'XPRS: $to was just reported heard — $moved held packet(s) sent on '
          '(12.8.1)');
    }
    return moved;
  }

  /// Where [target]'s mail should go, in 12.8.1's order: the recipient's own
  /// declaration, then every fresh live sighting, then -- only with neither --
  /// the freshest visit. Never ourselves, the recipient, or a hop the packet
  /// already took.
  List<String> _gatewaysFor(String target,
      {required String self, required Set<String> via}) {
    final out = <String>[];
    void add(String g) {
      final c = g.trim().toUpperCase();
      if (c.isEmpty || c == self || c == target || via.contains(c)) return;
      if (out.contains(c) || out.length >= maxGateways) return;
      out.add(c);
    }

    for (final h in _holders(target)) {
      add(h);
    }
    final sightings = _sightings(target);
    for (final s in sightings) {
      if (s.live) add(s.gateway);
    }
    if (out.isEmpty) {
      for (final s in sightings) {
        if (!s.live) {
          add(s.gateway);
          if (out.isNotEmpty) break;
        }
      }
    }
    return out;
  }

  void _remember(String key) {
    if (_sent.length >= _sentMax) _sent.remove(_sent.keys.first);
    _sent[key] = DateTime.now().millisecondsSinceEpoch;
  }

  // ── the device defaults, behind the seams ─────────────────────────────────

  bool _canDeliver(String call) =>
      (canDeliver ?? XprsMailbox.instance.reachable)?.call(call) ?? false;

  List<String> _holders(String call) =>
      (holdersOf ?? XprsArchive.instance.holdersFor)(call);

  List<GossipSighting> _sightings(String call) =>
      (sightingsOf ?? (c) => XprsGossip.instance.whereIs(c, max: maxGateways))(
          call);

  List<String> _named() =>
      namedArchivers?.call() ??
      PreferencesService.instanceSync?.xprsNamedArchivers ??
      const <String>[];

  Future<bool> _send(String gateway, String wire, {required String id}) async {
    final injected = sendTo;
    if (injected != null) return injected(gateway, wire);
    final hex = RnsService.instance.lxmfDestForCallsign(gateway);
    if (hex.isNotEmpty) {
      return RnsService.instance
          .wappSendTo('xprs', hex, Uint8List.fromList(utf8.encode(wire)));
    }
    // via: already carries us, so the broadcast cannot come back through.
    final report = await XprsPublisher.instance
        .publishWire(wire, verbatim: true, slot: 'fwd:$id');
    return report.values.any((v) => v == 'sent');
  }

  Map<String, dynamic> get json => {
        'forwarded': forwarded,
        'noRoute': noRoute,
        'loops': loops,
        'selfDelivers': selfDelivers,
        'retries': retries,
      };

  /// Tests: forget what was forwarded and every injected seam.
  void debugReset() {
    _sent.clear();
    _retriedMs.clear();
    forwarded = noRoute = loops = selfDelivers = retries = 0;
    heldFor = null;
    sendTo = null;
    canDeliver = null;
    holdersOf = null;
    sightingsOf = null;
    namedArchivers = null;
  }
}
