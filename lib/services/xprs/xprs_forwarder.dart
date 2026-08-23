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
import '../reticulum/rns_service.dart';
import 'xprs_archive.dart';
import 'xprs_gossip.dart';
import 'xprs_id.dart';
import 'xprs_packet.dart';
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
      noRoute++;
      return null;
    }

    // The directed lane: LXMF to the gateway when the network can name it.
    final hex = RnsService.instance.lxmfDestForCallsign(gateway);
    if (hex.isEmpty) return null; // radio custody lanes keep their own pace

    final carried = xprsAppendVia(p, selfBase);
    if (!carried.fits) return null; // a via: that no longer fits stays put
    final ok = await RnsService.instance.wappSendTo(
        'xprs', hex, Uint8List.fromList(utf8.encode(carried.encode())));
    _sent.add(id);
    if (_sent.length > 512) _sent.remove(_sent.first);
    if (ok) forwarded++;
    LogService.instance.add('XPRS: held mail for $target forwarded toward '
        '$gateway (${ok ? "delivered" : "stored"}) — 36.8.1');
    return gateway;
  }
}
