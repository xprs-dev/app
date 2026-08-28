/*
 * xprs_digipeat — repeating what we heard, on the medium we heard it
 * (docs/XPRS.md sections 13.1, 13.2, 13.2.1).
 *
 * The role table of section 0 gives a relay one job:
 *
 *   "repeats a packet on the medium it heard it, within the hop budget,
 *    appending itself to `via:`"
 *
 * This app did not do it on any bearer. On the wired ones that is defensible —
 * a phone is an endpoint and the ESP32s are the stations built to relay. On
 * Bluetooth it is not, because BLE is the one bearer where refusing to repeat
 * leaves stations unable to reach each other AT ALL: two phones out of range
 * have no other path between them, while anything on a wired bearer can still
 * be gatewayed. A room with three phones in it was three separate meshes.
 *
 * ── What stops a storm ──────────────────────────────────────────────────────
 *
 * Not restraint; four rules, and they are the specification's, not ours:
 *
 *   13.1   the type's hop budget — three relays for ordinary traffic, nine for
 *          sos and warning. Counted from `via:`, which is why it needs no field.
 *   13.2   our own callsign in `via:` and we do not touch it, whatever the
 *          count says. Plus: we do not repeat what we have already repeated.
 *   13.2.1 a short RANDOM wait before re-airing, and the copy is dropped if the
 *          packet is heard again during it. Every station in range hears the
 *          same packet at the same moment and is ready to transmit in the same
 *          instant; without the random wait they collide, and without the
 *          cancel they all transmit anyway.
 *   5      the identifier is computed with `sig:` and `via:` removed, so a copy
 *          relayed by somebody else IS the same packet and is recognised as
 *          one. "Somebody already said this" is decidable from the air.
 *
 * One subtlety, and it is the one the firmware states too: only a copy that has
 * ALREADY been relayed cancels ours. The origin repeating itself is the
 * opposite signal — it means nobody has carried the packet yet, which is
 * exactly when a digipeater should.
 */
import 'dart:async';
import 'dart:math';

import '../log_service.dart';
import 'xprs_id.dart';
import 'xprs_packet.dart';
import 'xprs_vocab.dart';

class _Pending {
  _Pending(this.wire, this.dueMs);
  final String wire;
  final int dueMs;
}

class XprsDigipeater {
  XprsDigipeater({
    required this.air,
    required this.relayable,
    required this.enabled,
  });

  /// Put one wire on the bearer. Returns false when the radio refused it.
  final Future<bool> Function(String wire) air;

  /// The 13.1/13.2 decision plus the `via:` append — MeshService._relayable,
  /// which is the same routine the 36.8.1 release uses. One rule, one place.
  final String? Function(String wire) relayable;

  /// Whether this bearer may transmit at all right now (the operator's switch
  /// and the API's `only:`/`disable:` test hook both land here).
  final bool Function() enabled;

  /// Test seams. The jitter is the whole mechanism, so a test that cannot fix
  /// the clock and the dice cannot test it.
  int Function() now = () => DateTime.now().millisecondsSinceEpoch;
  int Function(int max) random = Random().nextInt;

  /// 13.2.1's window. The same figures the firmware's shared engine uses, so
  /// a phone and a board in the same room back off on the same distribution.
  static const int jitterMinMs = 200;
  static const int jitterMaxMs = 1200;

  /// How long "already seen" lasts, for both rings.
  static const int seenMs = 60000;

  /// Waiting to be re-aired, by identifier.
  final Map<String, _Pending> _queue = {};

  /// Identifiers we have put on this bearer, so we never repeat ourselves.
  final Map<String, int> _aired = {};

  /// Bounded: a busy room must not turn this into a memory leak.
  static const int maxQueue = 8;
  static const int maxAired = 64;

  Timer? _timer;

  int cancelled = 0, aired = 0, refused = 0, dropped = 0;

  Map<String, dynamic> get json => {
        'queued': _queue.length,
        'aired': aired,
        'cancelled': cancelled,
        'refused': refused,
        'dropped': dropped,
      };

  /// Every XPRS packet heard on this bearer, duplicates included.
  ///
  /// Does the 13.2.1 cancel and the 13.1/13.2 decision in that order, because
  /// a packet that cancels ours must not then be queued by us.
  void heard(XprsPacket p, String wire) {
    final id = xprsIdentifier(p);
    if (id.isEmpty) return;
    _sweep();

    // Somebody ELSE got there first — and "else" is the load-bearing word.
    //
    // A non-empty `via:` is not enough to establish it. A station that wrongly
    // appends itself to the `via:` of its own packet (a defect real phones
    // shipped with, fixed here in MeshService._relayable and XprsForwarder but
    // still on the air from anything not yet updated) emits an ORIGIN copy
    // that reads as relayed. Cancelling on that means every digipeater in the
    // room stands down when the author merely repeats itself, which is the
    // opposite of what 13.2.1 asks for: the origin saying it again means
    // nobody has carried it yet, and that is precisely when we should.
    final from = (p['f'] ?? '').trim().toUpperCase();
    final byOthers =
        xprsVia(p).where((c) => c.trim().toUpperCase() != from).isNotEmpty;
    if (byOthers && _queue.remove(id) != null) {
      cancelled++;
      LogService.instance.add(
          'XPRS: digipeat $id cancelled — heard it relayed (13.2.1)');
      return;
    }
    if (!enabled()) return;
    if (_aired.containsKey(id) || _queue.containsKey(id)) return;

    final out = relayable(wire);
    if (out == null) {
      refused++;
      return;
    }
    if (_queue.length >= maxQueue) {
      dropped++;
      return;
    }
    final wait = jitterMinMs + random(jitterMaxMs - jitterMinMs + 1);
    _queue[id] = _Pending(out, now() + wait);
    _arm();
  }

  /// Air everything due. Public so a test can drive the clock instead of
  /// waiting on a real timer.
  Future<void> pump() async {
    final t = now();
    final due = [
      for (final e in _queue.entries)
        if (e.value.dueMs <= t) e.key
    ];
    for (final id in due) {
      final pend = _queue.remove(id);
      if (pend == null) continue;
      if (!enabled()) continue;
      _aired[id] = t;
      aired++;
      try {
        if (!await air(pend.wire)) refused++;
      } catch (e) {
        LogService.instance.add('XPRS: digipeat air failed: $e');
      }
    }
    _sweep();
    _arm();
  }

  void _arm() {
    _timer?.cancel();
    _timer = null;
    if (_queue.isEmpty) return;
    final t = now();
    var soonest = _queue.values.map((p) => p.dueMs).reduce(min) - t;
    if (soonest < 0) soonest = 0;
    // One timer for the whole queue, re-armed as it drains: a timer per
    // packet is how a busy room ends up with dozens of them (performance.md).
    _timer = Timer(Duration(milliseconds: soonest), pump);
  }

  void _sweep() {
    final t = now();
    _aired.removeWhere((_, at) => t - at > seenMs);
    if (_aired.length > maxAired) {
      final oldest =
          _aired.entries.reduce((a, b) => a.value <= b.value ? a : b).key;
      _aired.remove(oldest);
    }
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
    _queue.clear();
  }

  void reset() {
    dispose();
    _aired.clear();
    cancelled = aired = refused = dropped = 0;
  }
}
