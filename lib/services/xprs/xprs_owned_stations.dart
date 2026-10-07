/// The stations this profile owns, by their own word (`docs/XPRS.md` 11.9).
///
/// Ownership is a fact about the device and nothing announces it, so the
/// phone learns it the only two ways the device says it: the `t:result` that
/// answers a claim or a policy command, and the `t:observation s:policy` that
/// answers `q:policy`. Both carry `owner:`, both are the station's signed
/// statement, and only a VERIFIED one is believed: anyone can type
/// `owner:X1ME` into a packet. The newest statement wins in both directions,
/// so a station that hands itself to somebody else is forgotten here too.
///
/// What it is for: a station may ask its owner's phone where they both are
/// (`q:pos`, section 8), and the answer is a person's position, so it goes
/// to an owned station and nobody else; and an owned movable station (`X2`,
/// a card in the owner's pocket) is the first mailbox the owner declares
/// (9.12), because it sees the owner more than anything else does.
///
/// Pure apart from persistence, which is injected; the verify is the caller's
/// (it holds the key resolver, and verdicts are memoised there,
/// performance.md 8.15).
library;

import 'xprs_packet.dart';

class XprsOwnedStations {
  XprsOwnedStations._();
  static final XprsOwnedStations instance = XprsOwnedStations._();

  final Set<String> _owned = {};
  bool _loaded = false;

  /// Persistence, set at start: read once, written on every change.
  List<String> Function() load = () => const [];
  void Function(List<String>) save = (_) {};

  /// Told when the set changes (the mailbox declaration is re-aired).
  void Function()? onChanged;

  void _ensure() {
    if (_loaded) return;
    _loaded = true;
    _owned.addAll(load().map(_norm).where((c) => c.isNotEmpty));
  }

  bool isOwned(String call) {
    _ensure();
    return _owned.contains(_norm(call));
  }

  /// The owned movable stations (`X2`), in a stable order.
  List<String> get portable {
    _ensure();
    return _owned.where((c) => c.startsWith('X2')).toList()..sort();
  }

  List<String> get all {
    _ensure();
    return _owned.toList()..sort();
  }

  /// Is [p] a station saying who owns it? Cheap: no curve, decides whether
  /// the caller should spend a verify on it at all.
  static bool isOwnerStatement(XprsPacket p) =>
      p.has('owner') &&
      (p.type == 'result' || (p.type == 'observation' && p['s'] == 'policy'));

  /// Worth verifying? Only a statement that would CHANGE something: one that
  /// names us for a station we do not hold, or one from a station we hold.
  bool concerns(String from, String ownerCsv, String selfBase) {
    _ensure();
    return _owned.contains(_norm(from)) ||
        _list(ownerCsv).contains(_norm(selfBase));
  }

  /// A VERIFIED statement by [from] that its owners are [ownerCsv].
  void learn(String from, String ownerCsv, String selfBase) {
    _ensure();
    final st = _norm(from);
    if (st.isEmpty) return;
    final mine = _list(ownerCsv).contains(_norm(selfBase));
    final changed = mine ? _owned.add(st) : _owned.remove(st);
    if (!changed) return;
    save(_owned.toList()..sort());
    onChanged?.call();
  }

  static String _norm(String c) => c.trim().toUpperCase();

  static List<String> _list(String csv) => csv == 'none'
      ? const []
      : csv.split(',').map(_norm).where((c) => c.isNotEmpty).toList();

  /// Tests only.
  void resetForTest() {
    _owned.clear();
    _loaded = false;
    onChanged = null;
  }
}
