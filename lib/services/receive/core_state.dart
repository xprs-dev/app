/*
 * core_state — the core tells a wapp its state moved, so nothing has to ask.
 *
 * The event bus carried packets and nothing else. That was a real gap rather
 * than an omission: most of what a wapp draws is not a packet at all — the
 * station list, the traffic ring, the Reticulum graph, the archive's counters
 * — and with no way to be TOLD any of it changed, a wapp had exactly one
 * option, which was to ask on a timer.
 *
 * Measured across this tree before this file existed:
 *
 *   xprs       every 3 s   re-encodes 200 sightings + the station list to JSON
 *   mesh       every 2 s   re-encodes the whole Reticulum graph and hub list
 *   bluetooth  every 2 s   re-pushes the mesh topology
 *   archiver   every 5 s   re-reads the archive and node status
 *
 * All four ran whether or not anything had happened, forever, while the page
 * was open. docs/performance.md §3.2 has a name for this shape ("work redone
 * forever") and this is the largest instance of it in the app.
 *
 * ── What is published, and what is not ───────────────────────────────────
 *
 * A notification, not the data: `{"topic":…,"rev":N}`. The wapp then reads
 * what it already knows how to read (`hal_xprs_traffic`, `hal_rns_nodes`, …).
 * Pushing the payload would mean encoding it for every publication whether or
 * not anybody is subscribed, which is the cost we are removing.
 *
 * ── Coalescing is the point, not an optimisation ─────────────────────────
 *
 * A busy minute is hundreds of sightings. One publication per sighting would
 * be worse than the 3-second poll it replaces: the wapp re-reads the WHOLE
 * ring each time, so N notifications cost N full encodes. Changes inside one
 * window collapse into a single publication carrying the latest revision,
 * which is all a reader that re-reads everything can use.
 */
import 'dart:async';
import 'dart:convert';

import '../../wapp/wapp_event_broker.dart';

class CoreState {
  CoreState._();
  static final CoreState instance = CoreState._();

  /// The station table and the traffic ring ([XprsMonitor]).
  static const monitor = 'core.monitor';

  /// Reticulum's announced nodes and the hubs behind them.
  static const rnsGraph = 'core.rns.graph';

  /// The BLE mesh neighbour table and its routes.
  static const meshTopology = 'core.mesh.topology';

  /// The archive's counters and what this station is holding for others.
  static const archive = 'core.archive';

  /// A background task started, finished, paused or failed.
  static const tasks = 'core.tasks';

  /// Closed-group membership moved: an act was accepted, or a roster replayed
  /// differently (§26). Group membership is a core feature every wapp can use,
  /// so it is announced like any other core state.
  static const groups = 'core.groups';

  /// A datagram arrived on a wapp's own Reticulum tag. Per tag, because two
  /// wapps' private protocols are not each other's business:
  /// `core.datagram.<tag>`.
  ///
  /// The datagram already sits in that wapp's queue and is read the way it
  /// always was, with `hal_rns_recv`. What changes is that the wapp is TOLD,
  /// instead of asking once a second forever on the chance one arrived.
  static String datagram(String tag) => 'core.datagram.$tag';

  /// Every fixed topic this file publishes, for the subscription UI and for a
  /// test that wants to assert the list rather than a literal. `datagram` is
  /// not here: its topics are named after a wapp, not after core state.
  static const List<String> topics = [
    monitor,
    rnsGraph,
    meshTopology,
    archive,
    tasks,
    groups,
  ];

  /// How long changes are collected before one publication goes out.
  ///
  /// Short enough that a screen feels live, long enough that a burst of
  /// packets is one publication. A reader re-reads its whole view on each
  /// one, so the window is what stands between "told when it changed" and
  /// "told once per packet", which would cost more than the poll.
  static const Duration window = Duration(milliseconds: 250);

  final Map<String, int> _revision = {};
  final Set<String> _pending = {};
  Timer? _flush;

  static int published = 0;
  static int coalesced = 0;

  /// Test seam: what went out, without standing up an engine.
  static void Function(String topic, int rev)? onPublish;

  /// The state behind [topic] moved. Cheap and safe to call from a hot path:
  /// it bumps a counter and, only if anybody is listening, arms one timer.
  ///
  /// The revision moves either way, so a wapp that subscribes later still sees
  /// a number that reflects everything that happened — and it read its whole
  /// view at init regardless, which is what a revision is compared against.
  void changed(String topic) {
    _revision[topic] = (_revision[topic] ?? 0) + 1;
    // Nobody subscribed: there is nothing to deliver, so do not arm a timer to
    // deliver it. Silence has to cost nothing for any of this to be an
    // improvement on the poll it replaces.
    if (!WappEventBroker.instance.hasSubscriber(topic)) return;
    if (!_pending.add(topic)) coalesced++;
    _flush ??= Timer(window, _flushNow);
  }

  /// Current revision of [topic] — what the last publication carried.
  int revisionOf(String topic) => _revision[topic] ?? 0;

  void _flushNow() {
    _flush = null;
    if (_pending.isEmpty) return;
    final due = _pending.toList();
    _pending.clear();
    for (final topic in due) {
      final rev = _revision[topic] ?? 0;
      WappEventBroker.instance
          .publish('core', topic, jsonEncode({'topic': topic, 'rev': rev}));
      published++;
      try {
        onPublish?.call(topic, rev);
      } catch (_) {}
    }
  }

  /// Publish whatever is pending right now instead of at the end of the
  /// window. For a test, and for a caller that has just finished a batch and
  /// knows no more is coming.
  void flushForTest() {
    _flush?.cancel();
    _flushNow();
  }

  static void debugReset() {
    instance._flush?.cancel();
    instance._flush = null;
    instance._pending.clear();
    instance._revision.clear();
    published = 0;
    coalesced = 0;
    onPublish = null;
  }
}
