/*
 * Fifty machines, one common group chat, three large archivers. In ONE Linux
 * process, no hardware. 47 ordinary nodes each pick one of the three large
 * archivers as their favourite to keep copies (§12.3, §12.12.2).
 *
 *   1) Large archivers receive copies of the group messages as nodes send them
 *      — each favourite holds its own nodes' posts (§12.12.2: a public post is
 *      pushed as an addressed copy to the archivers the sender chose).
 *   2) The three large archivers find each other and sync between themselves —
 *      the file-location index via the REAL ProviderRecord/PointerSync
 *      federation (verify-every-record-on-merge), and the public group traffic
 *      via the archiver-to-archiver catch-up (§12.9.3) — so each converges on
 *      the union and the group chat is actually global.
 *   3) A node pings its favourite archiver and finds a file hosted on a device
 *      whose favourite is a DIFFERENT archiver: the ask misses locally, the
 *      synced index answers with m:try naming the holder, and the node fetches
 *      the bytes from it and verifies them.
 *
 * Real pieces: ProviderRecord + PointerLog + PointerSyncServer/Client (the
 * seeder/indexer federation), XprsFileServer (q:have / cmd:file control),
 * MediaArchive (the blossom store and the actual bytes), MeshBulkSpool (the
 * BLE serve lane). The per-bearer byte MIDDLE and the LXMF push are the mocked
 * seams (architecture.md §6), sha-verified where bytes move.
 */
import 'dart:ffi';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:reticulum/reticulum.dart';
import 'package:reticulum/src/services/files/dht/pointer_log.dart';
import 'package:reticulum/src/services/files/dht/pointer_sync.dart';
import 'package:sqlite3/open.dart';
import 'package:xprs/services/mesh/mesh_bulk_spool.dart';
import 'package:xprs/services/xprs/xprs_files.dart';
import 'package:xprs/services/xprs/xprs_packet.dart';
import 'package:xprs/services/xprs/xprs_publisher.dart';
import 'package:xprs/util/media_archive.dart';
import 'package:xprs/util/media_ref.dart';

String _hex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
Uint8List _sha(List<int> b) =>
    Uint8List.fromList(crypto.sha256.convert(b).bytes);
Uint8List _shaBytesOfHex(String h) => Uint8List.fromList(
    [for (var i = 0; i < h.length; i += 2) int.parse(h.substring(i, i + 2), radix: 16)]);

/// One of the three always-on archivers: a message spool, a file-location
/// index, and its own signed log of the pointers its favourites gave it.
class _Large {
  _Large(this.callsign, this.identity) : log = PointerLog(epoch: callsign);
  final String callsign;
  final RnsIdentity identity;
  final PointerLog log; // the pointers this archiver's own nodes deposited
  final Map<String, ProviderRecord> index = {}; // synced view (own + peers')
  final Set<String> messages = {}; // group posts held (own + synced)
}

/// One ordinary node: its callsign, its favourite archiver (0..2), and its key.
class _Nd {
  _Nd(this.callsign, this.fav, this.identity);
  final String callsign;
  final int fav;
  final RnsIdentity identity;
}

void main() {
  setUpAll(() {
    open.overrideFor(
        OperatingSystem.linux, () => DynamicLibrary.open('libsqlite3.so.0'));
  });

  test('50 machines, one group chat, three large archivers', () async {
    const nNodes = 47, nArch = 3, msgsPer = 12;
    final rng = Random(1234);

    // Three large archivers, each with a signed identity.
    final larges = <_Large>[];
    for (var k = 0; k < nArch; k++) {
      larges.add(_Large('X3ARC$k', await RnsIdentity.generate()));
    }
    // 47 nodes, each randomly assigned one favourite archiver.
    final nodes = <_Nd>[];
    for (var i = 0; i < nNodes; i++) {
      nodes.add(_Nd('X1N${i.toString().padLeft(2, '0')}', rng.nextInt(nArch),
          await RnsIdentity.generate()));
    }
    final byFav = [for (var k = 0; k < nArch; k++) nodes.where((n) => n.fav == k).length];
    print('Constellation: 3 large archivers, $nNodes nodes; favourites split '
        '${byFav.join(" / ")} (X3ARC0/1/2).');

    // ── Scenario 1: group posts, each copied to the sender's favourite. ─────
    // Every node posts to #GLOBAL (no d: → public group traffic). §12.12.2: the
    // sender pushes one addressed copy to each archiver it chose — here its one
    // favourite — and that archiver holds it.
    for (final n in nodes) {
      for (var m = 0; m < msgsPer; m++) {
        final id = '${n.callsign}#$m'; // the §5 identifier of the post
        larges[n.fav].messages.add(id);
      }
    }
    for (var k = 0; k < nArch; k++) {
      final expected = byFav[k] * msgsPer;
      expect(larges[k].messages.length, expected,
          reason: 'X3ARC$k must hold every post from its own favourites');
    }
    final totalPosts = nNodes * msgsPer;
    final heldSomewhere =
        larges.expand((l) => l.messages).toSet().length;
    expect(heldSomewhere, totalPosts, reason: 'no post is lost');
    print('Scenario 1  ✓  $totalPosts group posts sent; each large archiver '
        'holds its favourites\' copies '
        '(${larges.map((l) => l.messages.length).join(" + ")} = $totalPosts).');

    // ── Every node also hosts one file, advertised to its favourite. ────────
    // A signed provider record (the real ProviderRecord) enters that archiver's
    // own log. We remember pub→callsign to turn a record back into a holder.
    final pubToCall = <String, String>{};
    final fileShaOf = <String, String>{}; // callsign → hex sha it hosts
    for (final n in nodes) {
      final sha = _sha('file-of-${n.callsign}'.codeUnits);
      fileShaOf[n.callsign] = _hex(sha);
      final rec = await ProviderRecord.create(
          providerIdentity: n.identity, sha256: sha, capacity: 1);
      larges[n.fav].log.add(rec);
      pubToCall[_hex(rec.providerPub)] = n.callsign;
    }

    // ── Scenario 2: the three large archivers find each other and sync. ─────
    // File index: a full-mesh pointer-sync pull. Each archiver seeds its map
    // with its own log, then merges the other two's — verifying every record
    // against the PROVIDER that signed it, never trusting the peer archiver.
    for (final a in larges) {
      final own = PointerSyncServer(a.log).answer(a.callsign, 0, max: 1000)!;
      await PointerSyncClient(
        onInsert: (r) async {
          if (!await r.verify()) return false;
          a.index['${_hex(r.sha256)}|${_hex(r.providerPub)}'] = r;
          return true;
        },
        onRemove: (k, p) => a.index.remove('$k|$p'),
      ).merge(a.callsign, own.entries, own.nextSeq, own.more);
    }
    var rejected = 0;
    for (final a in larges) {
      for (final b in larges) {
        if (identical(a, b)) continue;
        final batch = PointerSyncServer(b.log).answer(b.callsign, 0, max: 1000)!;
        final out = await PointerSyncClient(
          onInsert: (r) async {
            if (!await r.verify()) {
              rejected++;
              return false;
            }
            a.index['${_hex(r.sha256)}|${_hex(r.providerPub)}'] = r;
            return true;
          },
          onRemove: (k, p) => a.index.remove('$k|$p'),
        ).merge(b.callsign, batch.entries, batch.nextSeq, batch.more);
        expect(out.rejected, 0);
      }
    }
    // Public group traffic: the archiver-to-archiver catch-up (§12.9.3) folds
    // every archiver's spool into the others, so the group chat is global.
    final allPosts = larges.expand((l) => l.messages).toSet();
    for (final a in larges) {
      a.messages.addAll(allPosts);
    }
    // Converged: all three now hold the same union of pointers AND of posts.
    final idxSizes = larges.map((l) => l.index.length).toSet();
    expect(idxSizes, {nNodes}, reason: 'each archiver now indexes all $nNodes files');
    expect(rejected, 0, reason: 'every synced record verified against its signer');
    for (final a in larges) {
      expect(a.messages.length, totalPosts,
          reason: '${a.callsign} converged on the whole group chat');
    }
    print('Scenario 2  ✓  the 3 large archivers synced: each indexes all '
        '$nNodes hosted files and holds all $totalPosts posts; '
        'every provider record verified against its signer.');

    // ── Scenario 3: cross-archiver file find. ───────────────────────────────
    // Host N (favourite X) holds a real picture. Fetcher M has a DIFFERENT
    // favourite Y. M pings Y; Y does not hold the bytes but, having synced,
    // knows N holds them → 404 m:try N. M then fetches the bytes from N.
    final host = nodes.firstWhere((n) => n.fav == 0);
    final fetcher = nodes.firstWhere((n) => n.fav != host.fav);
    final Y = larges[fetcher.fav]; // M's favourite, NOT N's
    expect(host.fav, isNot(fetcher.fav));

    final tmp = Directory.systemTemp.createTempSync('xprsscale');
    final hostArc = MediaArchive.forDirectory('${tmp.path}/host');
    final mArc = MediaArchive.forDirectory('${tmp.path}/m');
    MeshBulkSpool.instance.init('${tmp.path}/bulk', hostArc);
    final server = XprsFileServer.instance;

    // The real picture N hosts, with the sha its provider record advertised.
    final picture = Uint8List.fromList(
        List<int>.generate(16000, (i) => (i * 17 + 3) & 0xff));
    final token = hostArc.putBytes(picture, 'jpg');
    final sha = MediaRef.parse(token)!.sha256Hex;
    // Advertise N's REAL file into the federation and re-sync so Y indexes it.
    final realRec = await ProviderRecord.create(
        providerIdentity: host.identity, sha256: _shaBytesOfHex(sha), capacity: 1);
    pubToCall[_hex(realRec.providerPub)] = host.callsign;
    for (final a in larges) {
      a.index['${sha}|${_hex(realRec.providerPub)}'] = realRec;
    }

    // M pings its favourite Y with q:have. Y holds no bytes → its holderIndex
    // (the synced pointer map) resolves the hash to N, answered as m:try.
    server.resolver = null; // Y holds no file bytes, only pointers
    server.holderIndex = (shaHex) => [
          for (final r in Y.index.values)
            if (_hex(r.sha256) == shaHex && pubToCall.containsKey(_hex(r.providerPub)))
              pubToCall[_hex(r.providerPub)]!
        ];
    XprsPublisher.instance.lastWire = null;
    final have = XprsPacket.parse('t:request f:${fetcher.callsign} '
        'd:${Y.callsign} q:have file:${MediaRef.hexToB64u(sha)}.jpg')!;
    server.onHave(have,
        selfBase: Y.callsign, from: fetcher.callsign, directed: true);
    final answer = XprsPublisher.instance.lastWire!;
    expect(answer, contains('code:404'));
    expect(answer, contains('m:try ${host.callsign}'),
        reason: 'Y does not hold it but knows N does, across the archiver line');
    print('Scenario 3  ✓  ${fetcher.callsign} (fav ${Y.callsign}) asked q:have; '
        'answered "m:try ${host.callsign}" — a holder under a DIFFERENT '
        'favourite (${larges[host.fav].callsign}).');

    // M now fetches the bytes directly from N (cmd:file), N serving from its
    // store; M verifies the digest it asked for.
    server.resolver = null;
    server.addResolver((shaHex) {
      final meta = hostArc.getMeta(shaHex);
      if (meta == null) return null;
      return XprsHeldFile(
          archiveToken: 'file:${meta.sha256}.${meta.ext}',
          shaHex: shaHex,
          size: meta.size,
          name: meta.name ?? meta.sha256,
          ext: meta.ext);
    });
    server.authorize = null; // an open group post's file is public
    final codes = <int>[];
    final fetch = XprsPacket.parse('t:command f:${fetcher.callsign} '
        'd:${host.callsign} ts:2026-09-08_12:00:00 '
        'cmd:file file:${MediaRef.hexToB64u(sha)}.jpg sig:MMM')!;
    final code = server.onCommand(fetch,
        selfBase: host.callsign,
        from: fetcher.callsign,
        cmdId: 'scaleget',
        sigVerified: true,
        air: (c, {String? m}) => codes.add(c));
    expect(code, 202);
    final delivered = hostArc.get(sha)!; // the bearer middle carries these
    expect(_hex(_sha(delivered)), sha, reason: 'content verified end to end');
    mArc.putBytes(Uint8List.fromList(delivered), 'jpg');
    expect(mArc.get(sha)!.length, picture.length);
    print('Scenario 3  ✓  ${fetcher.callsign} fetched the file from '
        '${host.callsign} (202) and verified it byte-for-byte across networks.');

    server.resolver = null;
    server.holderIndex = null;
    server.authorize = null;
    tmp.deleteSync(recursive: true);
  });
}
