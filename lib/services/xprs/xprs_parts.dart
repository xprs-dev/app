/*
 * Rejoining a message that arrived in parts (docs/XPRS.md section 6.6).
 *
 * The app has split long messages on the way out for a long time and has never
 * had anything that joins them on the way in, so a multi-part message -- which
 * a sealed body reaches sooner, being ~40% larger than the text it replaces
 * (13.6) -- simply could not be read.
 *
 * Section 6.6, in full, because every clause here is one of its rules:
 *
 *   - Reassembly is keyed on `(f, ts)`. The parts of one message share a
 *     timestamp, so no identifier has to be transmitted to bind them.
 *   - A receiver joins the values in order with exactly one space between them.
 *   - Incomplete sets are held for 10 minutes and then discarded. **A partial
 *     message is never displayed.**
 *   - Parts may arrive in any order. A repeated part number is ignored.
 *   - A set is limited to 9 parts.
 *   - The identifier is that of the packet the parts reassemble into: every
 *     field from the first part, the body replaced by the joined text, and `n:`
 *     removed.
 *
 * Sealed parts are each sealed separately (section 9.2 per packet), so this
 * table joins PLAINTEXT: the caller opens each part's `x:` as it arrives and
 * offers what it read. A part that cannot be opened is not a part that arrived,
 * because a hole in the middle of a message must not close silently.
 */
import 'xprs_body.dart';
import 'xprs_packet.dart';

/// A message rebuilt from its parts.
class XprsReassembled {
  const XprsReassembled(this.packet, this.text, this.privacy, {this.sig});

  /// The packet the parts reassemble into: the first part's fields with `n:`
  /// removed and the body replaced by the joined text. Its section 5 identifier
  /// is the message's identifier, and a reply names that, never a part's.
  final XprsPacket packet;
  final String text;

  /// The form the parts arrived in. A set never mixes forms — see
  /// [XprsPartTable.offer].
  final XprsPrivacy privacy;

  /// The `sig:` a part carried, if any. Section 9.1.1 signs a split PLAIN
  /// message once, on the last part, over the packet the parts reassemble
  /// into — so the packet it verifies against is [packet] with this value
  /// re-attached, and only the caller (who knows the sender's key) can hold
  /// it against anything. Null when no part carried one.
  final String? sig;
}

class _Set {
  _Set(this.total, this.first, this.privacy, this.at);
  final int total;
  final XprsPacket first;
  final XprsPrivacy privacy;
  final DateTime at;
  final Map<int, String> parts = {};

  /// The signature seen on whichever part carried one (9.1.1: the last).
  String? sig;
}

/// Buffers the parts of incoming split messages until each set is complete.
class XprsPartTable {
  /// Section 6.6: "Incomplete sets are held for 10 minutes and then discarded."
  static const Duration hold = Duration(minutes: 10);

  /// A bound on how many part-sets may be in flight at once. Section 6.6 gives
  /// a set a 10-minute life and no limit on how many sets exist, so a stranger
  /// airing first-parts that never complete would otherwise grow this table for
  /// ten minutes at whatever rate they can transmit. The oldest set is dropped
  /// first, which is also the one closest to expiring anyway.
  static const int maxSets = 64;

  final Map<String, _Set> _sets = {};

  int get pending => _sets.length;

  /// Offer one part. Returns the finished message when [p] completed its set,
  /// null while the set is still short — which is also what a partial message
  /// must look like to everything above, since it is never displayed.
  ///
  /// [clear] is the part's text, already opened by the caller when the body was
  /// sealed. Pass null for a sealed part that could not be opened: the set then
  /// cannot complete, which is correct — half a message with a hole in it is
  /// not the message.
  XprsReassembled? offer(XprsPacket p, {String? clear, DateTime? now}) {
    final at = now ?? DateTime.now();
    sweep(at);
    final n = p['n'];
    if (n == null) return null;
    final slash = n.indexOf('/');
    if (slash < 0) return null;
    final i = int.tryParse(n.substring(0, slash));
    final total = int.tryParse(n.substring(slash + 1));
    // Section 4.3: a `ratio` is two digits 1 to 9. Section 6.6: "A set is
    // limited to 9 parts". Anything else is a malformed value and is skipped.
    if (i == null || total == null) return null;
    if (i < 1 || total < 1 || total > 9 || i > total) return null;
    if (clear == null) return null;

    final from = p['f'] ?? '';
    final ts = p['ts'] ?? '';
    // Keyed on (f, ts) exactly as 6.6 says. Without `ts:` there is nothing to
    // bind parts with and two messages from one station would merge.
    if (from.isEmpty || ts.isEmpty) return null;
    final key = '$from|$ts';
    final privacy = p.has('x') ? XprsPrivacy.sealed : XprsPrivacy.plain;

    var set = _sets[key];
    if (set != null && (set.total != total || set.privacy != privacy)) {
      // The same (f, ts) arriving with a different part count, or switching
      // between sealed and plain mid-set, is not the message we were building.
      // Start again from what just arrived rather than joining two.
      set = null;
    }
    if (set == null) {
      if (_sets.length >= maxSets) {
        final oldest = _sets.entries
            .reduce((a, b) => a.value.at.isBefore(b.value.at) ? a : b)
            .key;
        _sets.remove(oldest);
      }
      set = _Set(total, p, privacy, at);
      _sets[key] = set;
    }
    // "A repeated part number is ignored" — the first copy heard wins.
    set.parts.putIfAbsent(i, () => clear);
    // Keep the joined-packet signature for the caller (9.1.1).
    final psig = p['sig'];
    if (psig != null && psig.isNotEmpty) set.sig = psig;
    // Keep the lowest-numbered part as the envelope donor: 6.6 builds the
    // reassembled packet from "every field from the first part", and parts
    // arrive in any order.
    if (i == 1) _sets[key] = _adopt(set, p, at);
    if (set.parts.length < total) return null;

    _sets.remove(key);
    final joined = [
      for (var k = 1; k <= total; k++) set.parts[k]!,
    ].join(' ');
    final head = set.first.without({'n', 'sig', 'x', 'm'});
    return XprsReassembled(head.with_('m', joined), joined, set.privacy,
        sig: set.sig);
  }

  _Set _adopt(_Set old, XprsPacket first, DateTime at) {
    final s = _Set(old.total, first, old.privacy, old.at);
    s.parts.addAll(old.parts);
    s.sig = old.sig;
    return s;
  }

  /// Discard sets older than [hold]. Cheap and called on every offer, so no
  /// timer of its own (docs/performance.md section 8.3).
  void sweep([DateTime? now]) {
    if (_sets.isEmpty) return;
    final at = now ?? DateTime.now();
    _sets.removeWhere((_, s) => at.difference(s.at) >= hold);
  }

  void clear() => _sets.clear();
}
