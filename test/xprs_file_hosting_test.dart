/*
 * An archiver hosts chat media on `cmd:file`, blossom style (XPRS.md §11.2,
 * §12.9.2), gated by the file's audience (§11.2): the hash is public, the bytes
 * are served only to a caller authorised for the file. In-process, no hardware:
 * a real MediaArchive + MeshBulkSpool + the profile-backed XprsFileAcl on temp
 * dirs, driven through XprsFileServer.onCommand exactly as the history-server
 * dispatch drives it.
 */
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/open.dart';
import 'package:xprs/services/mesh/mesh_bulk_spool.dart';
import 'package:xprs/services/xprs/xprs_file_acl.dart';
import 'package:xprs/services/xprs/xprs_files.dart';
import 'package:xprs/services/xprs/xprs_packet.dart';
import 'package:xprs/services/xprs/xprs_publisher.dart';
import 'package:xprs/util/media_archive.dart';
import 'package:xprs/util/media_ref.dart';
import 'package:reticulum/src/services/social/archiver_policy.dart';

void main() {
  late Directory tmp;
  late MediaArchive archive;
  late XprsFileServer server;
  late List<int> aired;

  setUpAll(() {
    open.overrideFor(
        OperatingSystem.linux, () => DynamicLibrary.open('libsqlite3.so.0'));
  });

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('xprshost');
    archive = MediaArchive.forDirectory(tmp.path);
    MeshBulkSpool.instance.init('${tmp.path}/bulk', archive);
    XprsFileAcl.instance.init('${tmp.path}/xprs_file_acl.sqlite3');

    server = XprsFileServer.instance;
    server.resolver = null; // clears the chain
    // The mesh registration under test: serve MediaArchive blobs by digest,
    // gated by the ACL — the same closures mesh_service installs.
    server.addResolver((shaHex) {
      final meta = archive.getMeta(shaHex);
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
    server.holderIndex = (shaHex) {
      final out = <String>[];
      for (final (kind, value) in archive.getSources(shaHex)) {
        if (kind == 'callsign' && value.trim().isNotEmpty) {
          out.add(value.trim().toUpperCase());
        }
      }
      return out;
    };
    aired = [];
  });

  tearDown(() {
    server.resolver = null;
    server.authorize = null;
    server.holderIndex = null;
    server.admit = null;
    XprsFileAcl.instance.close();
    tmp.deleteSync(recursive: true);
  });

  /// Put a blob, return its lowercase-hex sha and the `file:` token.
  (String sha, String token) putBlob(List<int> bytes, String ext) {
    final token = archive.putBytes(Uint8List.fromList(bytes), ext);
    return (MediaRef.parse(token)!.sha256Hex, token);
  }

  int serve(String sha, String from, {bool sigVerified = false}) {
    final ref = '${MediaRef.hexToB64u(sha)}.png';
    final p = XprsPacket.parse(
        't:command f:$from d:X3ARC ts:2026-08-13_10:14:00 cmd:file file:$ref')!;
    return server.onCommand(p,
        selfBase: 'X3ARC',
        from: from,
        cmdId: 'aa11bb',
        sigVerified: sigVerified,
        air: (code, {String? m}) => aired.add(code));
  }

  test('a public (unbound) file is served to any caller', () {
    final (sha, _) = putBlob([1, 2, 3, 4, 5], 'png');
    final code = serve(sha, 'X1QZ3N');
    expect(code, 202);
    expect(aired, [202]);
    expect(MeshBulkSpool.instance.holds(sha), isTrue,
        reason: 'the bytes were queued on the bulk lane for the asker');
  });

  test('a private (pair) file: served to a participant, refused to a stranger',
      () {
    final (sha, _) = putBlob([9, 9, 9, 9], 'jpg');
    XprsFileAcl.instance
        .bind(sha, scope: XprsFileScope.pair, members: ['X1AAA1', 'X3ARC']);

    // A participant, with a verified signature → served.
    expect(serve(sha, 'X1AAA1', sigVerified: true), 202);
    // A stranger, even with a verified signature → refused.
    expect(serve(sha, 'X9ZZZ9', sigVerified: true), 403);
  });

  test('a private file is refused to an UNSIGNED caller, even a participant',
      () {
    final (sha, _) = putBlob([7, 7, 7], 'png');
    XprsFileAcl.instance
        .bind(sha, scope: XprsFileScope.pair, members: ['X1AAA1', 'X3ARC']);
    // No proven identity: a private file cannot be served on a bare claim.
    expect(serve(sha, 'X1AAA1', sigVerified: false), 403);
  });

  test('binding a public scope re-opens a file to anyone', () {
    final (sha, _) = putBlob([4, 2], 'png');
    XprsFileAcl.instance.bind(sha, scope: XprsFileScope.public);
    expect(serve(sha, 'X9ZZZ9', sigVerified: false), 202);
  });

  int put(String from, {String size = 'size:240kB'}) {
    server.admit ??= null;
    final p = XprsPacket.parse('t:command f:$from d:X3ARC '
        'ts:2026-08-13_10:14:00 cmd:put file:${MediaRef.hexToB64u(
            'bb22cc33dd44ee55ff66aa11bb22cc33dd44ee55ff66aa11bb22cc33dd44ee55')}.jpg '
        '$size')!;
    return server.onPut(p,
        selfBase: 'X3ARC',
        from: from,
        cmdId: 'put001',
        via: ArrivedOver.bluetooth,
        air: (code, {String? m}) => aired.add(code));
  }

  test('cmd:put with deposits off is refused 403 (§34.3, not an archiver)', () {
    server.admit = null;
    expect(put('X1AAA1'), 403);
  });

  test('cmd:put accepted answers 202', () {
    server.admit = (from, bytes, via) => const ArchiveVerdict.yes();
    expect(put('X1AAA1'), 202);
  });

  test('cmd:put over quota answers 429', () {
    server.admit = (from, bytes, via) => const ArchiveVerdict.no('archive full');
    expect(put('X1AAA1'), 429);
  });

  test('cmd:put without size: is 400 (§11.2 size is mandatory)', () {
    server.admit = (from, bytes, via) => const ArchiveVerdict.yes();
    expect(put('X1AAA1', size: ''), 400);
  });

  test('q:have miss names holders from the sources index (§8.1, §12.9.2)', () {
    // A hash we do NOT hold, but the archive knows a callsign that does — a
    // seeder-index answer, not the bytes.
    const other =
        'ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00';
    archive.addSource(other, 'callsign', 'X3ARC7');
    final p = XprsPacket.parse('t:request f:X1QZ3N d:X3ARC q:have '
        'file:${MediaRef.hexToB64u(other)}.png')!;
    server.onHave(p, selfBase: 'X3ARC', from: 'X1QZ3N', directed: true);
    expect(XprsPublisher.instance.lastWire, contains('code:404'));
    expect(XprsPublisher.instance.lastWire, contains('m:try X3ARC7'));
  });
}
