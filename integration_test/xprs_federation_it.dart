/*
 * The stress harness, on real hardware.
 *
 * The same [Constellation] the desktop tests use, run under
 * IntegrationTestWidgetsFlutterBinding so it executes on a connected phone:
 *
 *     flutter test integration_test/xprs_federation_it.dart -d <device-id>
 *
 * The federation scenarios (group posts copied to favourites, the three large
 * archivers finding each other and syncing via the REAL ProviderRecord/
 * PointerSync, cross-archiver holder resolution) are pure Dart plus real
 * crypto — no sqlite, no platform stubs, no desktop-only sqlite override. So
 * what passes here is byte-for-byte the code path that runs on the device, and
 * the on-machine desktop run and the on-hardware run exercise the same harness.
 *
 * A smaller node count than the 50-machine desktop sweep: an integration run
 * spends real device keygen on every node, so this proves portability, not
 * scale — the scale sweep stays on the desktop (test/xprs_scale_50_test.dart).
 */
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import '../test/support/xprs_sim.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('federation harness runs on this device', (tester) async {
    const msgsPer = 6;
    final sim = await Constellation.build(nodes: 12, archivers: 3, seed: 7);

    // 1) Group posts copied to each sender's favourite.
    final total = sim.postGroup(msgsPer);
    for (var k = 0; k < sim.nArch; k++) {
      expect(sim.larges[k].messages.length, sim.favourites(k) * msgsPer);
    }
    expect(sim.larges.expand((l) => l.messages).toSet().length, total);

    // 2) The large archivers find each other and sync (real federation).
    final shas = await sim.hostSyntheticFiles();
    final rejected = await sim.syncLargeArchivers();
    expect(rejected, 0);
    expect(sim.larges.map((l) => l.index.length).toSet(), {sim.nodes.length});
    for (final a in sim.larges) {
      expect(a.messages.length, total);
    }

    // 3) A hash hosted under one favourite resolves through a different one.
    final host = sim.nodes.firstWhere((n) => n.fav == 0);
    final fetcher = sim.nodes.firstWhere((n) => n.fav != host.fav);
    final holders =
        sim.holdersAt(sim.larges[fetcher.fav], shas[host.callsign]!);
    expect(holders, contains(host.callsign),
        reason: 'the synced index at M\'s favourite points to N under X');

    print('Device federation harness OK: $total posts, '
        '${sim.nodes.length} files indexed at all ${sim.nArch} archivers, '
        'cross-archiver resolve → ${host.callsign}.');
  });
}
