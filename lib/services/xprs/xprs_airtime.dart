/*
 * One airtime budget across every bearer (docs/XPRS.md §31.1).
 *
 * Two rules in that section cannot be implemented inside a per-subsystem timer,
 * and until this file existed neither was implemented at all:
 *
 *   "A station transmits unsolicited traffic no more often than the STRICTEST
 *    bearer it is transmitting on allows. A phone that gateways to both LoRa
 *    and the internet is bound by LoRa, not by the internet, for anything it
 *    sends to both."
 *
 *   "A retry is not a new packet, so re-airing something that went unanswered
 *    counts against the same budget as saying it the first time."
 *
 * Both are about the WHOLE station. There were eleven independent schedulers —
 * the file fetch at 45 s, the catch-up ladder, the courier pump at 5 s, the
 * suppression sweep at 120 s, the LXMF retry ladder at 1 s, two beacons, the
 * history pager, the release pacing, the identity ask — each correct on its own
 * and none of them aware that the other ten were also transmitting.
 *
 * ── What this is not ────────────────────────────────────────────────────────
 *
 * Not a queue and not a scheduler. Callers keep their own cadence; they ask
 * here whether the air can afford the packet, and are told yes, or told to come
 * back later. A budget that took ownership of WHEN things are sent would have
 * to understand every one of those eleven policies, and it does not need to.
 *
 * Not a duty-cycle regulator either. `charge` is the honest arithmetic of what
 * a bearer owes after a transmission; the legal duty cycle on a LoRa ISM band
 * is the operator's to configure, and the default here is deliberately the
 * strict one (§31.4: the stations worth protecting are the ones that cannot
 * argue back).
 */
import '../log_service.dart';

/// What one bearer owes after transmitting, and how much of it may be spent.
///
/// `perPacketMs` is the silence a single 250-byte packet buys — the honest
/// shape of §31.1's table:
///
/// | bearer | what binds |
/// |---|---|
/// | LoRa on ISM | a legal duty cycle, often 1 % — at SF9 one packet owes several seconds |
/// | Bluetooth | a five-second-a-minute transmit window (docs/ble5.md §1) |
/// | LAN, internet | "nothing, which is the trap" |
class XprsBearerCost {
  const XprsBearerCost(this.name, this.perPacketMs);
  final String name;

  /// Milliseconds of silence one packet owes on this bearer. Zero means
  /// unmetered, which is a real answer and not a missing one.
  final int perPacketMs;

  /// At SF9 a single packet owes several seconds — §31.1's own example, and the
  /// only bearer here bound by law rather than by courtesy.
  static const lora = XprsBearerCost('lora', 6000);

  /// **Unmetered, on the specification's own word.** §31.1's table puts
  /// Bluetooth and WiFi Direct under "range, so traffic is naturally local and
  /// cheap". The five-second-a-minute window (docs/ble5.md §1) is a property of
  /// the advertising bus, which rotates registered frames within it — enqueuing
  /// one more is a registration, not a transmission, so charging per packet
  /// here would price something that does not happen.
  static const ble5 = XprsBearerCost('ble5', 0);

  /// "the internet | nothing, which is the trap" — the trap being a station
  /// that treats the internet's zero cost as the whole station's, which is
  /// exactly what [XprsAirtime.may] exists to prevent.
  static const lan = XprsBearerCost('lan', 0);
  static const reticulum = XprsBearerCost('reticulum', 0);

  static const defaults = <String, XprsBearerCost>{
    'lora': lora,
    'ble5': ble5,
    'lan': lan,
    'reticulum': reticulum,
  };
}

/// Why a packet was not aired now.
enum XprsAirVerdict {
  /// The air can afford it.
  ok,

  /// The strictest bearer this packet would go out on is still owed silence.
  /// Deferred, not dropped — the caller comes back.
  deferred,
}

class XprsAirtime {
  XprsAirtime._();
  static final XprsAirtime instance = XprsAirtime._();

  Map<String, XprsBearerCost> costs = Map.of(XprsBearerCost.defaults);

  /// Test seam so a unit test can run a day of traffic in a millisecond.
  int Function() now = () => DateTime.now().millisecondsSinceEpoch;

  /// When each bearer is next free, by name.
  final Map<String, int> _freeAt = {};

  /// Packets deferred, and the last reason — the observable that says the
  /// budget is alive. A budget nobody can see is indistinguishable from a
  /// station that has gone quiet.
  int deferrals = 0;
  int charged = 0;
  String lastDeferredBy = '';

  /// True when [bearers] can carry a packet right now.
  ///
  /// **The strictest bearer binds.** Not the average and not the one the caller
  /// prefers: a packet going to both LoRa and the internet waits for LoRa,
  /// which is §31.1's own example.
  ///
  /// Unmetered bearers never block, so a station with no radio is never held
  /// up by this — the trap §31.1 names is the opposite one, a station that
  /// treats the internet's zero cost as the whole station's.
  XprsAirVerdict may(Iterable<String> bearers) {
    final t = now();
    var strictest = '';
    var until = 0;
    for (final b in bearers) {
      final free = _freeAt[b] ?? 0;
      if (free > t && free > until) {
        until = free;
        strictest = b;
      }
    }
    if (until == 0) return XprsAirVerdict.ok;
    deferrals++;
    lastDeferredBy = strictest;
    return XprsAirVerdict.deferred;
  }

  /// Charge [bearers] for one packet.
  ///
  /// Called after a bearer accepted a wire, once per packet per bearer — and
  /// **a retry charges exactly as much as the first airing**, because it is the
  /// same transmission as far as the medium is concerned. Nothing here knows or
  /// cares whether this packet has been sent before; that is the point.
  void charge(Iterable<String> bearers, {int packets = 1}) {
    final t = now();
    for (final b in bearers) {
      final c = costs[b];
      if (c == null || c.perPacketMs == 0) continue;
      final base = (_freeAt[b] ?? 0) > t ? _freeAt[b]! : t;
      _freeAt[b] = base + c.perPacketMs * packets;
      charged += packets;
    }
  }

  /// Milliseconds until [bearer] is free, 0 when it is free now.
  int owedBy(String bearer) {
    final free = _freeAt[bearer] ?? 0;
    final t = now();
    return free > t ? free - t : 0;
  }

  void reset() {
    _freeAt.clear();
    deferrals = 0;
    charged = 0;
    lastDeferredBy = '';
  }

  Map<String, dynamic> get json => {
        'deferrals': deferrals,
        'charged': charged,
        'lastDeferredBy': lastDeferredBy,
        'owed': {
          for (final e in _freeAt.entries)
            if (owedBy(e.key) > 0) e.key: owedBy(e.key)
        },
      };
}

/// One entry per PACKET, however many lanes it is on and however many times it
/// has been tried (§31.1: "a retry is not a new packet").
///
/// The eleven schedulers each kept their own idea of "have I sent this, and
/// when may I send it again". Keyed on the §5 identifier, which every re-airing
/// of the same packet shares — a relayed copy included, since the identifier is
/// computed with `via:` removed.
class XprsRetryLedger {
  XprsRetryLedger._();
  static final XprsRetryLedger instance = XprsRetryLedger._();

  int Function() now = () => DateTime.now().millisecondsSinceEpoch;

  final Map<String, _Entry> _e = {};
  static const int _max = 256;

  /// Attempts spent on [id] so far.
  int attempts(String id) => _e[id]?.n ?? 0;

  /// May [id] be aired now?
  ///
  /// [reachable] is §13.7.2's rule, and it is the one that stops a station
  /// nursing undelivered mail from holding a channel down: *"a retry is spent
  /// only against evidence that the peer can still be reached, because a
  /// station that cannot hear its peer learns nothing by transmitting at it
  /// again"*. With no evidence the entry PARKS — not dropped, and no rung
  /// burned, so a peer that returns in an hour resumes its ladder rather than
  /// having spent it into an empty room.
  bool may(String id, {required bool reachable, List<int>? ladderS}) {
    final e = _e[id];
    if (e == null) return true;
    if (!reachable) return false;
    final ladder = ladderS ?? defaultLadderS;
    // After the FIRST attempt the wait is the first rung, so the index is
    // attempts-1. Indexing by `n` skipped a rung and made every ladder start
    // one step further up than it reads.
    final wait = ladder[(e.n - 1).clamp(0, ladder.length - 1)];
    return now() - e.at >= wait * 1000;
  }

  /// Record an airing of [id].
  void spend(String id) {
    if (_e.length >= _max && !_e.containsKey(id)) {
      // Oldest out. The ledger is a politeness memory, not a delivery record —
      // MeshStore is what remembers what is owed.
      final oldest =
          _e.entries.reduce((a, b) => a.value.at <= b.value.at ? a : b).key;
      _e.remove(oldest);
    }
    final e = _e[id];
    if (e == null) {
      _e[id] = _Entry(now(), 1);
    } else {
      e
        ..at = now()
        ..n += 1;
    }
  }

  /// Delivered, receipted, or otherwise finished: stop counting it.
  void retire(String id) => _e.remove(id);

  int get tracked => _e.length;
  void reset() => _e.clear();

  /// 2 s, 5 s, 10 s, 20 s, 1 min, 5 min, 30 min — the ladder the LXMF lane
  /// already used, lifted here so every lane climbs the same one.
  static const List<int> defaultLadderS = [2, 5, 10, 20, 60, 300, 1800];

  Map<String, dynamic> get json => {'tracked': tracked};
}

class _Entry {
  _Entry(this.at, this.n);
  int at;
  int n;
}

/// Wire the budget into the publisher's report without the publisher having to
/// know what a duty cycle is.
void xprsLogDeferral(String slot, String bearer, int owedMs) {
  LogService.instance.add(
      'XPRS: $slot deferred ${owedMs}ms — $bearer is the strictest bearer '
      'this packet rides (31.1)');
}
