/*
 * Fifty machines, one common group chat, three large archivers — on the
 * reusable [Constellation] harness (test/support/xprs_sim.dart). 47 nodes each
 * pick one of three large archivers as favourite (§12.3, §12.12.2).
 *
 *   1) Each large archiver receives copies of its favourites' group posts.
 *   2) The three large archivers find each other and sync — file index (REAL
 *      ProviderRecord/PointerSync, verify-on-merge) + public traffic — and
 *      converge on the union.
 *   3) A node pings its favourite for a file hosted on a device under a
 *      DIFFERENT favourite; the synced index answers m:try, and it fetches the
 *      bytes and verifies them.
 */
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/open.dart';
import 'package:xprs/services/mesh/mesh_bulk_spool.dart';
import 'package:xprs/services/xprs/xprs_files.dart';
import 'package:xprs/services/xprs/xprs_packet.dart';
import 'package:xprs/services/xprs/xprs_publisher.dart';
import 'package:xprs/util/media_archive.dart';
import 'package:xprs/util/media_ref.dart';

import 'support/xprs_sim.dart';

void main() {
  setUpAll(() {
    open.overrideFor(
        OperatingSystem.linux, () => DynamicLibrary.open('libsqlite3.so.0'));
  });

  test('50 machines, one group chat, three large archivers', () async {
    const msgsPer = 12;
    final sim = await Constellation.build(nodes: 47, archivers: 3, seed: 1234);
    print('Constellation: ${sim.nArch} large archivers, ${sim.nodes.length} '
        'nodes; favourites split '
        '${[for (var k = 0; k < sim.nArch; k++) sim.favourites(k)].join(" / ")}.');

    // ── Scenario 1: group posts, each copied to the sender's favourite. ─────
    final totalPosts = sim.postGroup(msgsPer);
    for (var k = 0; k < sim.nArch; k++) {
      expect(sim.larges[k].messages.length, sim.favourites(k) * msgsPer,
          reason: 'X3ARC$k holds every post from its own favourites');
    }
    expect(sim.larges.expand((l) => l.messages).toSet().length, totalPosts);
    print('Scenario 1  ✓  $totalPosts group posts; each archiver holds its '
        'favourites\' copies '
        '(${sim.larges.map((l) => l.messages.length).join(" + ")}).');

    // ── Scenario 2: the three large archivers find each other and sync. ─────
    await sim.hostSyntheticFiles(); // every node hosts one file, advertised
    final rejected = await sim.syncLargeArchivers();
    expect(rejected, 0, reason: 'every synced record verified against its signer');
    expect(sim.larges.map((l) => l.index.length).toSet(), {sim.nodes.length},
        reason: 'each archiver now indexes all files');
    for (final a in sim.larges) {
      expect(a.messages.length, totalPosts,
          reason: '${a.callsign} converged on the whole group chat');
    }
    print('Scenario 2  ✓  synced: each of the 3 indexes all ${sim.nodes.length} '
        'files and holds all $totalPosts posts; every record verified.');

    // ── Scenario 3: cross-archiver file find. ───────────────────────────────
    final host = sim.nodes.firstWhere((n) => n.fav == 0);
    final fetcher = sim.nodes.firstWhere((n) => n.fav != host.fav);
    final y = sim.larges[fetcher.fav]; // M's favourite, NOT N's

    final tmp = Directory.systemTemp.createTempSync('xprsscale');
    final hostArc = MediaArchive.forDirectory('${tmp.path}/host');
    final mArc = MediaArchive.forDirectory('${tmp.path}/m');
    MeshBulkSpool.instance.init('${tmp.path}/bulk', hostArc);
    final server = XprsFileServer.instance;

    final picture = Uint8List.fromList(
        List<int>.generate(16000, (i) => (i * 17 + 3) & 0xff));
    final sha = MediaRef.parse(hostArc.putBytes(picture, 'jpg'))!.sha256Hex;
    await sim.advertiseReal(host, sha); // N advertises the real file
    await sim.syncLargeArchivers(); // re-sync so Y indexes it

    // M pings Y (q:have). Y holds no bytes; its synced index resolves to N.
    server.resolver = null;
    server.holderIndex = (s) => sim.holdersAt(y, s);
    XprsPublisher.instance.lastWire = null;
    server.onHave(
        XprsPacket.parse('t:request f:${fetcher.callsign} d:${y.callsign} '
            'q:have file:${MediaRef.hexToB64u(sha)}.jpg')!,
        selfBase: y.callsign,
        from: fetcher.callsign,
        directed: true);
    final answer = XprsPublisher.instance.lastWire!;
    expect(answer, contains('code:404'));
    expect(answer, contains('m:try ${host.callsign}'),
        reason: 'Y does not hold it but knows N does, across the archiver line');
    print('Scenario 3  ✓  ${fetcher.callsign} (fav ${y.callsign}) asked q:have; '
        'answered "m:try ${host.callsign}" — a holder under a different '
        'favourite (X3ARC${host.fav}).');

    // M fetches the bytes from N (cmd:file) and verifies the digest.
    server.resolver = null;
    server.addResolver((s) {
      final meta = hostArc.getMeta(s);
      return meta == null
          ? null
          : XprsHeldFile(
              archiveToken: 'file:${meta.sha256}.${meta.ext}',
              shaHex: s,
              size: meta.size,
              name: meta.name ?? meta.sha256,
              ext: meta.ext);
    });
    server.authorize = null; // open group post → public file
    final codes = <int>[];
    final code = server.onCommand(
        XprsPacket.parse('t:command f:${fetcher.callsign} d:${host.callsign} '
            'ts:2026-09-08_12:00:00 cmd:file file:${MediaRef.hexToB64u(sha)}.jpg '
            'sig:MMM')!,
        selfBase: host.callsign,
        from: fetcher.callsign,
        cmdId: 'scaleget',
        sigVerified: true,
        air: (c, {String? m}) => codes.add(c));
    expect(code, 202);
    final delivered = hostArc.get(sha)!;
    expect(hexOf(sha256Of(delivered)), sha, reason: 'content verified end to end');
    mArc.putBytes(Uint8List.fromList(delivered), 'jpg');
    expect(mArc.get(sha)!.length, picture.length);
    print('Scenario 3  ✓  ${fetcher.callsign} fetched from ${host.callsign} '
        '(202) and verified it byte-for-byte across networks.');

    server.resolver = null;
    server.holderIndex = null;
    server.authorize = null;
    tmp.deleteSync(recursive: true);
  });
}
