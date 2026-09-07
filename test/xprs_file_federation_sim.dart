/*
 * A file-hosting simulation, whole, in ONE Linux process, no hardware.
 *
 * The scenarios the operator asked for, run end to end against the real core:
 *
 *   1) A shares a picture; a copy is deposited at A's chosen archiver C
 *      (cmd:put), and C STORES it (blossom host).
 *   2) B fetches that picture from C by hash (cmd:file), gated by the file's
 *      audience — a participant gets the bytes, a stranger is refused; content
 *      integrity is checked end to end.
 *   3) The seeder/indexer sync: C advertises the hash as a signed provider
 *      record and a large archiver D folds it into its index, so a global user
 *      asking D learns the file is at C — small archivers reporting upward, no
 *      archiver holding the whole network.
 *
 * The control (cmd:put / cmd:file), the audience gate (XprsFileAcl), and the
 * blossom store (MediaArchive) are the real singletons; the seeder federation
 * is the real ProviderRecord + PointerSync from reticulum-dart. The per-bearer
 * byte MIDDLE (GATT/MSP on BLE, a Reticulum resource or swarm on the internet)
 * is the one thing mocked — architecture.md §6: the bearer is the seam, and a
 * handoff here is sha-verified exactly as the real lanes verify. The real byte
 * lanes themselves are exercised by mesh_bulk_spool_test / file_transfer_test /
 * piece_engine_test; this proves the control, the gate and the sync tie them
 * together.
 *
 * It prints a transcript, so running it reads as the scenario playing out.
 */
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:reticulum/reticulum.dart';
import 'package:reticulum/src/services/files/dht/pointer_log.dart';
import 'package:reticulum/src/services/files/dht/pointer_sync.dart';
import 'package:sqlite3/open.dart';
import 'package:xprs/services/mesh/mesh_bulk_spool.dart';
import 'package:xprs/services/xprs/xprs_file_acl.dart';
import 'package:xprs/services/xprs/xprs_files.dart';
import 'package:xprs/services/xprs/xprs_packet.dart';
import 'package:xprs/util/media_archive.dart';
import 'package:xprs/util/media_ref.dart';
import 'package:reticulum/src/services/social/archiver_policy.dart';

/// One simulated station's own content-addressed store.
class _Node {
  _Node(this.callsign, String dir) : archive = MediaArchive.forDirectory(dir);
  final String callsign;
  final MediaArchive archive;
}

String _hex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

void main() {
  late Directory tmp;
  late _Node a, b, c, d; // author, fetcher, chosen archiver, large archiver
  final server = XprsFileServer.instance;
  final aired = <int>[];

  setUpAll(() {
    open.overrideFor(
        OperatingSystem.linux, () => DynamicLibrary.open('libsqlite3.so.0'));
  });

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('xprsfedsim');
    a = _Node('X1AUTH', '${tmp.path}/a');
    b = _Node('X1BOB2', '${tmp.path}/b');
    c = _Node('X3ARC1', '${tmp.path}/c'); // the chosen archiver
    d = _Node('X3BIGD9', '${tmp.path}/d'); // the large/always-on archiver
    XprsFileAcl.instance.init('${tmp.path}/acl.sqlite3');
    MeshBulkSpool.instance.init('${tmp.path}/c/bulk', c.archive);
    server.resolver = null;
    server.authorize = null;
    server.admit = null;
  });

  tearDown(() {
    server.resolver = null;
    server.authorize = null;
    server.admit = null;
    XprsFileAcl.instance.close();
    tmp.deleteSync(recursive: true);
  });

  /// Point C's file server at C's store, gated by the ACL — the mesh_service
  /// wiring, aimed at this node.
  void beC() {
    server.resolver = null;
    server.addResolver((shaHex) {
      final meta = c.archive.getMeta(shaHex);
      if (meta == null) return null;
      return XprsHeldFile(
        archiveToken: 'file:${meta.sha256}.${meta.ext}',
        shaHex: shaHex,
        size: meta.size,
        name: meta.name ?? meta.sha256,
        ext: meta.ext,
      );
    });
    server.authorize = (sha, requester, {required bool sigVerified}) {
      final scope = XprsFileAcl.instance.scopeOf(sha);
      if (scope == null || scope == XprsFileScope.public) return true;
      if (!sigVerified) return false;
      return XprsFileAcl.instance.authorized(sha, requester);
    };
  }

  test('the whole file-hosting federation, in one process', () async {
    // ── The picture A wants to share, in a 1:1 to B (private). ──────────────
    final picture = Uint8List.fromList(
        List<int>.generate(20000, (i) => (i * 31 + 7) & 0xff));
    final wantHex = _hex(crypto.sha256.convert(picture).bytes);
    final token = a.archive.putBytes(picture, 'jpg'); // A self-hosts its own
    final sha = MediaRef.parse(token)!.sha256Hex;
    expect(sha, wantHex);
    print('A composed a 1:1 to B with $token (${picture.length} B); '
        'A self-hosts it (every device is an archiver).');

    // ── Scenario 1: A deposits a copy at its chosen archiver C (cmd:put). ───
    beC();
    server.admit = (from, bytes, via) => const ArchiveVerdict.yes(); // C opted in
    aired.clear();
    final putWire = XprsPacket.parse('t:command f:X1AUTH d:X3ARC1 '
        'ts:2026-09-08_10:00:00 cmd:put $token size:20000 sig:KKK')!;
    final putCode = server.onPut(putWire,
        selfBase: 'X3ARC1',
        from: 'X1AUTH',
        cmdId: 'put01',
        via: ArrivedOver.internet,
        air: (code, {String? m}) => aired.add(code));
    expect(putCode, 202);
    // The bytes then travel the per-bearer middle to C, which stores them as a
    // hosted blob and binds the file's audience (this was a 1:1 A↔B).
    expect(_hex(crypto.sha256.convert(picture).bytes), sha); // C verifies
    c.archive.putHosted(picture, 'jpg', originPubHex: 'A', tier: 0);
    XprsFileAcl.instance
        .bind(sha, scope: XprsFileScope.pair, members: ['X1AUTH', 'X1BOB2']);
    expect(c.archive.has(sha), isTrue);
    print('Scenario 1  ✓  C accepted the deposit (202) and now HOSTS the '
        'picture; audience bound to the A↔B pair.');

    // ── Scenario 2: B fetches the picture from C by hash (cmd:file). ────────
    // B is a participant and signs its ask → served. The bytes cross the middle
    // and B verifies them against the digest it asked for.
    final ref = '${MediaRef.hexToB64u(sha)}.jpg';
    final fetchWire = XprsPacket.parse('t:command f:X1BOB2 d:X3ARC1 '
        'ts:2026-09-08_10:01:00 cmd:file file:$ref sig:BBB')!;
    aired.clear();
    final code = server.onCommand(fetchWire,
        selfBase: 'X3ARC1',
        from: 'X1BOB2',
        cmdId: 'get01',
        sigVerified: true, // B's signature verified as X1BOB2
        air: (c2, {String? m}) => aired.add(c2));
    expect(code, 202);
    // The per-bearer middle delivers; B hashes what arrived (the integrity the
    // real lanes enforce) and keeps it only if it matches.
    final delivered = c.archive.get(sha)!;
    expect(_hex(crypto.sha256.convert(delivered).bytes), sha);
    b.archive.putBytes(Uint8List.fromList(delivered), 'jpg');
    expect(b.archive.get(sha)!.length, picture.length);
    print('Scenario 2  ✓  B asked C by hash (202) and received a '
        'byte-identical copy over the bearer lane.');

    // A stranger E, even with a good signature, is not in the audience.
    aired.clear();
    final strangerWire = XprsPacket.parse('t:command f:X9EVE9 d:X3ARC1 '
        'ts:2026-09-08_10:02:00 cmd:file file:$ref sig:EEE')!;
    final strangerCode = server.onCommand(strangerWire,
        selfBase: 'X3ARC1',
        from: 'X9EVE9',
        cmdId: 'get02',
        sigVerified: true,
        air: (c2, {String? m}) => aired.add(c2));
    expect(strangerCode, 403);
    expect(b.archive.has(sha), isTrue);
    print('Scenario 2  ✓  a stranger asking the same hash was refused 403 '
        '(the hash is public, the bytes are not).');

    // ── Scenario 3: C tells the large archiver D where the file lives. ──────
    // C advertises a SIGNED provider record; D (an indexer) folds it into its
    // map via the pointer-sync federation. Nobody trusts D or C blindly — the
    // provider signs the record, D verifies it on the way in.
    final cId = await RnsIdentity.generate();
    final shaBytes = Uint8List.fromList([
      for (var i = 0; i < 64; i += 2) int.parse(sha.substring(i, i + 2), radix: 16)
    ]);
    final record = await ProviderRecord.create(
        providerIdentity: cId, sha256: shaBytes, capacity: 1); // kCapArchive
    expect(await record.verify(), isTrue);

    final cLog = PointerLog(epoch: 'C1')..add(record);
    final cServer = PointerSyncServer(cLog);
    final dMap = <String, ProviderRecord>{};
    final dClient = PointerSyncClient(
      onInsert: (r) async {
        // D verifies every record against the PROVIDER before it enters the map.
        if (!await r.verify()) return false;
        dMap['${_hex(r.sha256)}|${_hex(r.providerPub)}'] = r;
        return true;
      },
      onRemove: (k, p) => dMap.remove('$k|$p'),
    );
    final batch = cServer.answer('C1', 0, max: 16)!;
    final merged =
        await dClient.merge('C1', batch.entries, batch.nextSeq, batch.more);
    expect(merged.applied, 1);

    // A global user asks D "where is this hash?" — D answers from its index.
    final holders = dMap.values
        .where((r) => _hex(r.sha256) == sha)
        .map((r) => _hex(r.providerPub))
        .toList();
    expect(holders, hasLength(1));
    expect(holders.single, _hex(record.providerPub));
    print('Scenario 3  ✓  C advertised the hash as a signed provider record; '
        'D (large archiver) merged it and now points a global user at C.');
    print('             D holds a POINTER, not the bytes — the seeder/tracker '
        'split, done with signed claims and no central server.');
  });
}
