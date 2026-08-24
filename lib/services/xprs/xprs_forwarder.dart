/*
 * xprs_forwarder — mail migrates toward the recipient (XPRS.md 36.8.1).
 *
 * A station holding mail for X that it cannot deliver hands the held wire —
 * as CUSTODY, the author's signature intact — toward where X actually is:
 * X's own declared mailbox first (13.12, consulted in its order), the
 * freshest gossip gateway second (36.9.4). Once per holder: our callsign
 * joins `via:`, and a wire whose `via:` already names us (or the chosen
 * gateway) is not forwarded again. The directed lane is Reticulum's
 * wappSendTo when the gateway resolves; the radio custody lanes keep doing
 * what they always did for gateways in radio reach.
 */
import 'dart:convert';
import 'dart:typed_data';

import '../log_service.dart';
import '../preferences_service.dart';
import '../reticulum/rns_service.dart';
import 'xprs_archive.dart';
import 'xprs_gossip.dart';
import 'xprs_id.dart';
import 'xprs_packet.dart';
import 'xprs_publisher.dart';
import 'xprs_vocab.dart';

class XprsForwarder {
  XprsForwarder._();
  static final XprsForwarder instance = XprsForwarder._();

  int forwarded = 0, noRoute = 0, loops = 0;

  /// One forward per (packet, this holder): the id set remembers what we
  /// already pushed so a re-heard copy does not go around again.
  final Set<String> _sent = {};

  /// Try to move one held wire toward [target]. Returns the gateway callsign
  /// it went to, or null when it stayed here (no route, loop, or no lane).
  Future<String?> maybeForward(String target, String wire,
      {required String selfBase}) async {
    final p = XprsPacket.parse(wire);
    if (p == null) return null;
    final id = xprsIdentifier(p);
    if (_sent.contains(id)) return null;

    final via = (p['via'] ?? '')
        .split(',')
        .map((c) => c.trim().toUpperCase())
        .where((c) => c.isNotEmpty)
        .toSet();
    if (via.contains(selfBase)) {
      loops++;
      return null; // it already passed through us once (13.2)
    }

    // Where X actually is: the recipient's word, then the freshest sighting.
    final supers = PreferencesService.instanceSync?.xprsSuperArchivers ??
        const <String>[];
    final candidates = <String>[
      ...XprsArchive.instance.holdersFor(target),
      for (final s in XprsGossip.instance.whereIs(target, max: 4)) s.gateway,
    ];
    String? gateway;
    for (final g in candidates) {
      if (g == selfBase || g == target || via.contains(g)) continue;
      gateway = g;
      break;
    }
    if (gateway == null) {
      // Gossip knows nothing: ask a super-archiver (the answer feeds the
      // next attempt), and meanwhile DEPOSIT the mail with one -- 36.12
      // step 1, "hand it to any archiver" -- rather than sitting on it.
      XprsGossip.instance.askSuper(target,
          publish: (w) async =>
              XprsPublisher.instance.publishWire(w, slot: 'ask:$target'),
          superArchivers: supers,
          selfBase: selfBase);
      for (final sa in supers) {
        final g = sa.trim().toUpperCase();
        if (g.isEmpty || g == selfBase || via.contains(g)) continue;
        gateway = g;
        break;
      }
    }
    if (gateway == null) {
      noRoute++;
      return null;
    }

    final carried = xprsAppendVia(p, selfBase);
    if (!carried.fits) return null; // a via: that no longer fits stays put
    final wire2 = carried.encode();

    // The directed lane first: LXMF to the gateway when the network can
    // name it. An ESP32 gateway has no LXMF letterbox, so the fallback is
    // the broadcast custody re-air -- every bearer, verbatim, the gateway
    // hears it like any packet and holds it as the mail it is (36.11
    // class 2). via: already carries us, so it cannot come back through.
    var lane = 'broadcast';
    var ok = false;
    final hex = RnsService.instance.lxmfDestForCallsign(gateway);
    if (hex.isNotEmpty) {
      lane = 'lxmf';
      ok = await RnsService.instance
          .wappSendTo('xprs', hex, Uint8List.fromList(utf8.encode(wire2)));
    } else {
      final report = await XprsPublisher.instance
          .publishWire(wire2, verbatim: true, slot: 'fwd:$id');
      ok = report.values.any((v) => v == 'sent');
    }
    _sent.add(id);
    if (_sent.length > 512) _sent.remove(_sent.first);
    if (ok) forwarded++;
    LogService.instance.add('XPRS: held mail for $target forwarded toward '
        '$gateway over $lane (${ok ? "carried" : "kept"}) — 36.8.1');
    return gateway;
  }
}
