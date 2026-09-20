/*
 * xprs_gateway_dedup — one message of another network, however many gateways
 * translated it.
 *
 * XPRS.md 9.11.5: a gateway dates what it translates to the minute and carries
 * the other network's own identifier of the message in a private key (`zmid:`),
 * so two gateways that hear one Meshtastic transmission compose the same
 * packet and the same section 5 identifier. Except across a minute boundary:
 * one gateway hears the frame at 12:03:59.8, another at 12:04:00.1 after a
 * relay, and the two packets differ in `ts:` and so in their identifier. The
 * section 5 dedup keeps both, and a person reads the same words twice.
 *
 * `zmid:` is the second line behind the identifier. The same `zmid:` under a
 * DIFFERENT identifier is the same message translated twice; the same one
 * under the same identifier is an ordinary repeat, which the identifier dedup
 * already handles and this does not count.
 *
 * Checked at the one receive door (PacketGateway), where a split
 * translation (6.6) still arrives as its parts. Every part carries the
 * message's `zmid:` and has an identifier of its own, so the key is `zmid:`
 * and the part number together: part 2 of one translation is not a repeat of
 * its part 1, and part 2 from two gateways is the same part twice.
 *
 * Pure and bounded: a map lookup per packet that carries the key, nothing for
 * one that does not, 256 entries and ten minutes at most.
 */
import 'dart:collection';

import 'xprs_id.dart';
import 'xprs_packet.dart';

class XprsGatewayDedup {
  XprsGatewayDedup({this.cap = 256, this.windowMs = 10 * 60 * 1000});

  /// The one table the wapp door and the courier share, so a translation that
  /// reached one of them is known to the other.
  static final XprsGatewayDedup instance = XprsGatewayDedup();

  final int cap;
  final int windowMs;

  final LinkedHashMap<String, ({String id, int ms})> _seen = LinkedHashMap();

  /// Second translations dropped.
  int duplicates = 0;

  /// True when [p] is a message of another network that was already handed
  /// on under a different identifier. Remembers [p] otherwise.
  bool duplicate(XprsPacket p, {int? nowMs}) {
    final zmid = (p['zmid'] ?? '').trim();
    if (zmid.isEmpty) return false;
    final part = (p['n'] ?? '').trim();
    final z = part.isEmpty ? zmid : '$zmid/$part';
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    final id = xprsIdentifier(p);
    final had = _seen[z];
    if (had != null && now - had.ms <= windowMs) {
      if (had.id == id) return false;
      duplicates++;
      return true;
    }
    _seen.remove(z);
    _seen[z] = (id: id, ms: now);
    while (_seen.length > cap) {
      _seen.remove(_seen.keys.first);
    }
    return false;
  }

  void debugReset() {
    _seen.clear();
    duplicates = 0;
  }
}
