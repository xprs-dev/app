// The file faults of docs/plan-archiver-tests.md section 3, each as a test of
// the behaviour the one file system must have. A test here is skipped with its
// fault number while the fault stands, so the suite stays green and the fault
// stays written down; run them as they are with
//
//   flutter test --run-skipped test/xprs_file_faults_test.dart
//
// and remove the `skip:` when the fault is fixed. Faults F1, F2, F7 and F8 are
// missing machinery (no size on the internet lane, no file lane off Bluetooth,
// no infohash passed, no firmware responder): there is no behaviour to drive
// until the one fetch door exists, and they are tested with it.
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:xprs/services/media/media_fetch.dart';
import 'package:xprs/services/mesh/mesh_bulk_spool.dart';
import 'package:xprs/services/mesh/mesh_session.dart';
import 'package:xprs/services/mesh/mesh_store.dart';
import 'package:xprs/services/xprs/xprs_files.dart';
import 'package:xprs/services/xprs/xprs_id.dart';
import 'package:xprs/services/xprs/xprs_inline_file.dart';
import 'package:xprs/services/xprs/xprs_packet.dart';
import 'package:xprs/services/xprs/xprs_publisher.dart';
import 'package:xprs/util/media_archive.dart';
import 'package:xprs/util/media_ref.dart';

class _Recorder implements XprsBearer {
  final List<String> sent = [];
  @override
  String get name => 'ble5';
  @override
  String get archiveBearer => 'ble';
  @override
  bool get shortRange => true;
  @override
  Future<bool> get active async => true;
  @override
  Future<XprsSendResult> send(String wire,
      {required int part,
      String slot = 'status',
      Duration? ttl,
      bool datagram = false,
      bool verbatim = false}) async {
    sent.add(wire);
    return XprsSendResult.sent;
  }
}

const _sha =
    '72088e1a542fda167831a58b2c2b07aba76d246a4673536f1ebdeba78707173a';

void main() {
  late _Recorder air;
  late Directory tmp;
  late MediaArchive archive;

  setUp(() {
    air = _Recorder();
    XprsPublisher.instance.bearers = [air];
    XprsFileFetch.instance.internetFetch = null;
    tmp = Directory.systemTemp.createTempSync('xprsfaults');
    archive = MediaArchive.forDirectory(tmp.path);
    MeshBulkSpool.instance.init('${tmp.path}/bulk', archive);
    MeshStore.instance.init('${tmp.path}/mesh.zx');
  });

  tearDown(() {
    XprsFileFetch.instance.internetFetch = null;
    XprsFileServer.instance.resolver = null;
    MeshBulkSpool.instance.inboundClaim = null;
    MeshStore.instance.close();
    tmp.deleteSync(recursive: true);
  });

  List<XprsPacket> asks() => [
        for (final w in air.sent)
          if (w.contains('cmd:file')) XprsPacket.parse(w)!
      ];

  // ── F3: a 404 that names holders is followed ───────────────────────────
  test('F3: a 404 with m:try is followed to the holder it names', () async {
    final fut = XprsFileFetch.instance.fetch(
      archiver: 'X3AAAA',
      shaHex: _sha,
      selfCallsign: 'X1SELF',
      ext: 'jpg',
      timeout: const Duration(seconds: 3),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final first = asks().single;
    XprsFileFetch.instance.onResult(XprsPacket.parse(
        't:result f:X3AAAA d:X1SELF ts:2026-11-21_08:00:00 '
        'r:${xprsIdentifier(first)} code:404 m:try X3BBBB,X3CCCC')!);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(asks().map((p) => p['d']), contains('X3BBBB'),
        reason: 'the archiver said who holds it (spec 8.1, 12.9.2); '
            'the fetch must ask there instead of ending');
    await fut;
  });

  // ── F10: a second holder is asked when the first was already asked ────
  test('F10: asking a second archiver for the same file reaches it', () async {
    final a = XprsFileFetch.instance.fetch(
        archiver: 'X3AAAA',
        shaHex: _sha,
        selfCallsign: 'X1SELF',
        ext: 'jpg',
        timeout: const Duration(seconds: 2));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final b = XprsFileFetch.instance.fetch(
        archiver: 'X3BBBB',
        shaHex: _sha,
        selfCallsign: 'X1SELF',
        ext: 'jpg',
        timeout: const Duration(seconds: 2));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(asks().map((p) => p['d']).toSet(), {'X3AAAA', 'X3BBBB'},
        reason: 'one fetch per file, but every holder named is a source');
    await Future.wait([a, b]);
  });

  // ── One fetch, several holders: the edges ─────────────────────────────
  XprsPacket refusal(XprsPacket ask, int code, {String? m}) =>
      XprsPacket.parse('t:result f:${ask['d']} d:X1SELF '
          'ts:2026-11-21_08:00:00 r:${xprsIdentifier(ask)} code:$code'
          '${m == null ? '' : ' m:$m'}')!;

  test('one holder refusing does not end a fetch another may still answer',
      () async {
    final a = XprsFileFetch.instance.fetch(
        archiver: 'X3AAAA',
        shaHex: _sha,
        selfCallsign: 'X1SELF',
        timeout: const Duration(seconds: 2));
    XprsFileFetch.instance.fetch(
        archiver: 'X3BBBB',
        shaHex: _sha,
        selfCallsign: 'X1SELF',
        timeout: const Duration(seconds: 2));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    var done = false;
    // ignore: unawaited_futures
    a.whenComplete(() => done = true);
    final toA = asks().firstWhere((p) => p['d'] == 'X3AAAA');
    XprsFileFetch.instance.onResult(refusal(toA, 404));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(done, isFalse, reason: 'X3BBBB was asked and has not answered');
    final toB = asks().firstWhere((p) => p['d'] == 'X3BBBB');
    XprsFileFetch.instance.onResult(refusal(toB, 404));
    expect(await a, isNull, reason: 'now every holder asked has refused');
  });

  test('a redirect is followed one hop, and never back to ourselves',
      () async {
    final a = XprsFileFetch.instance.fetch(
        archiver: 'X3AAAA',
        shaHex: _sha,
        selfCallsign: 'X1SELF',
        timeout: const Duration(seconds: 2));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    XprsFileFetch.instance
        .onResult(refusal(asks().single, 404, m: 'try X3BBBB,X1SELF'));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(asks().map((p) => p['d']), ['X3AAAA', 'X3BBBB']);
    // X3BBBB was reached by a redirect: where it points is not followed.
    final toB = asks().firstWhere((p) => p['d'] == 'X3BBBB');
    XprsFileFetch.instance.onResult(refusal(toB, 404, m: 'try X3CCCC'));
    expect(await a, isNull);
    expect(asks().map((p) => p['d']), isNot(contains('X3CCCC')));
  });

  test('the bytes arriving from any holder end the fetch for every caller',
      () async {
    final a = XprsFileFetch.instance.fetch(
        archiver: 'X3AAAA',
        shaHex: _sha,
        selfCallsign: 'X1SELF',
        timeout: const Duration(seconds: 2));
    final b = XprsFileFetch.instance.fetch(
        archiver: 'X3BBBB',
        shaHex: _sha,
        selfCallsign: 'X1SELF',
        timeout: const Duration(seconds: 2));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    XprsFileFetch.instance.noteInboundComplete(_sha, '/tmp/got.bin');
    expect(await a, '/tmp/got.bin');
    expect(await b, '/tmp/got.bin');
    expect(XprsFileFetch.instance.busy, isFalse);
  });

  // ── Holders are remembered (spec 12.9.2) ──────────────────────────────
  test('a station that answers 202 is remembered as a holder of the file',
      () async {
    XprsFileFetch.instance.onHolder =
        (sha, holder) => archive.addSource(sha, 'callsign', holder);
    addTearDown(() => XprsFileFetch.instance.onHolder = null);
    expect(xprsKnownHolders(archive, _sha), isEmpty);
    final fut = XprsFileFetch.instance.fetch(
        archiver: 'X3AAAA',
        shaHex: _sha,
        selfCallsign: 'X1SELF',
        timeout: const Duration(seconds: 2));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    XprsFileFetch.instance.onResult(refusal(asks().single, 202));
    expect(xprsKnownHolders(archive, _sha), ['X3AAAA'],
        reason: 'what a q:have miss names in m:try, and what the next '
            'fetch of this file asks beside its sender');
    XprsFileFetch.instance.noteInboundComplete(_sha, '/tmp/x');
    await fut;
  });

  // ── The exact length, from the holder's 202 (spec 11.2) ───────────────
  test('a 202 that states the length makes the piece path possible',
      () async {
    final lane = <int>[];
    XprsFileFetch.instance.internetFetch = (sha, ext, archiver, destDir) async {
      lane.add(XprsFileFetch.instance.exactSizeOf(sha));
      return null;
    };
    final fut = XprsFileFetch.instance.fetch(
        archiver: 'X3AAAA',
        shaHex: _sha,
        selfCallsign: 'X1SELF',
        timeout: const Duration(seconds: 2));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(lane, [0], reason: 'asked before anyone said how long it is');
    final ask = asks().single;
    XprsFileFetch.instance.onResult(XprsPacket.parse(
        't:result f:X3AAAA d:X1SELF ts:2026-11-21_08:00:00 '
        'r:${xprsIdentifier(ask)} code:202 size:3145728')!);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(XprsFileFetch.instance.exactSizeOf(_sha), 3145728);
    expect(lane, [0, 3145728],
        reason: 'the internet lane runs again, now able to fetch by pieces');
    XprsFileFetch.instance.noteInboundComplete(_sha, '/tmp/x');
    await fut;
  });

  test('a one-piece file does not restart the internet lane', () async {
    var runs = 0;
    XprsFileFetch.instance.internetFetch = (sha, ext, archiver, destDir) async {
      runs++;
      return null;
    };
    final fut = XprsFileFetch.instance.fetch(
        archiver: 'X3AAAA',
        shaHex: _sha,
        selfCallsign: 'X1SELF',
        timeout: const Duration(seconds: 2));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    XprsFileFetch.instance.onResult(XprsPacket.parse(
        't:result f:X3AAAA d:X1SELF ts:2026-11-21_08:00:00 '
        'r:${xprsIdentifier(asks().single)} code:202 size:5000')!);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(runs, 1, reason: 'one piece: its own hash verifies it');
    XprsFileFetch.instance.noteInboundComplete(_sha, '/tmp/x');
    await fut;
  });

  // ── F4: two requesters of one file ────────────────────────────────────
  group('F4: two stations ask one holder for the same file', () {
    late String sha;
    late List<String> results;

    int serve(String from, String cmdId) {
      final ref = '${MediaRef.hexToB64u(sha)}.png';
      final p = XprsPacket.parse('t:command f:$from d:X3ARC '
          'ts:2026-11-21_08:00:00 cmd:file file:$ref')!;
      return XprsFileServer.instance.onCommand(p,
          selfBase: 'X3ARC',
          from: from,
          cmdId: cmdId,
          sigVerified: false,
          air: (code, {String? m}) => results.add('$from:$code'));
    }

    setUp(() {
      results = [];
      final token = archive.putBytes(
          Uint8List.fromList(List.generate(4000, (i) => i & 0xFF)), 'png');
      sha = MediaRef.parse(token)!.sha256Hex;
      final server = XprsFileServer.instance;
      server.resolver = null;
      server.addResolver((h) {
        final meta = archive.getMeta(h);
        if (meta == null) return null;
        return XprsHeldFile(
            archiveToken: 'file:${meta.sha256}.${meta.ext}',
            shaHex: h,
            size: meta.size,
            name: meta.name ?? meta.sha256,
            ext: meta.ext);
      });
    });

    test('both are owed the bytes', () {
      expect(serve('X1AAAA', 'aa0001'), 202);
      expect(serve('X1BBBB', 'bb0002'), 202);
      final targets = [
        for (final e in (MeshBulkSpool.instance.statusJson()['entries']
            as List<dynamic>))
          ...((e as Map)['targets'] as List? ?? [e['target']])
      ];
      expect(targets, containsAll(['X1AAAA', 'X1BBBB']),
          reason: 'each was answered 202; the spool must owe each a copy');
    });

    test('each gets its closing 200 when its copy verified', () async {
      serve('X1AAAA', 'aa0001');
      serve('X1BBBB', 'bb0002');
      air.sent.clear();
      XprsFileServer.instance.noteHandedOver(sha, 'X1AAAA');
      XprsFileServer.instance.noteHandedOver(sha, 'X1BBBB');
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final closed = [
        for (final w in air.sent)
          if (w.contains('code:200')) XprsPacket.parse(w)!['d']
      ];
      expect(closed, containsAll(['X1AAAA', 'X1BBBB']));
    });
  });

  // ── F5: the requester is found under any form of its callsign ─────────
  test('F5: a file addressed to the bare callsign is claimed by its device',
      () {
    final data =
        Uint8List.fromList(List.generate(9000, (i) => (i * 7 + 3) & 0xFF));
    final sha = Uint8List.fromList(crypto.sha256.convert(data).bytes);
    final o = MspFileOffer(
        xfer: 1,
        sha256: sha,
        size: data.length,
        ttlS: 3600,
        origin: 'X3ARC',
        // What the holder writes: the asker's bare `f:`.
        target: 'X1SELF',
        ext: 'bin',
        name: 'f.bin');
    var claimed = false;
    MeshBulkSpool.instance.inboundClaim = (hex, path, meta) {
      claimed = true;
      return null;
    };
    MeshBulkSpool.instance.offered('X3ARC', o);
    MeshBulkSpool.instance.writeAt(sha, 0, data);
    expect(MeshBulkSpool.instance.verify(sha), isTrue);
    // This device answers as X1SELF-2 (section 3.1: one person, two devices).
    MeshBulkSpool.instance.completeInbound(sha, selfCallsign: 'X1SELF-2');
    expect(claimed, isTrue,
        reason: 'the file is ours; held as relay custody instead, the '
            'fetch that asked for it waits for its timeout');
  });

  // ── F6: a file of unknown size is not sent down the packet lane blind ─
  test('F6: unknown size on a link is not treated as a packet-lane file', () {
    final lane = MediaFetch.decide(
        size: null, link: true, bleOnly: false, maxMb: 50, userTapped: true);
    expect(lane, isNot(MediaLane.packet),
        reason: 'over 32 kB the holder refuses a packet-lane ask (403) and '
            'nothing falls back; with a link the bulk and internet lanes '
            'carry any size');
    // Nobody asked: the bounded guess stands, whatever the link.
    expect(
        MediaFetch.decide(
            size: null, link: true, bleOnly: false, maxMb: 50, userTapped: false),
        MediaLane.packet);
  });

  // ── F11: a re-send on another grid still completes the file ───────────
  test('F11: gaps re-sent on a different grid still assemble the file', () {
    final data =
        Uint8List.fromList(List.generate(3000, (i) => (i * 13 + 1) & 0xFF));
    // The holder first aired the file to everybody, then re-sends it to the
    // one station that asked (`d:`): a longer header, so a shorter chunk, so
    // the same bytes cut at different offsets.
    final first = xprsInlineSplit(data, from: 'X3HOLD', ext: 'bin');
    final again =
        xprsInlineSplit(data, from: 'X3HOLD', to: 'X1SELF', ext: 'bin');
    final gridA = int.parse(XprsPacket.parse(first[1])!['off']!);
    final gridB = int.parse(XprsPacket.parse(again[1])!['off']!);
    expect(gridA, isNot(gridB),
        reason: 'the two grids must differ for this test to mean anything');
    final asm = XprsInlineAsm(timers: false);
    Uint8List? got;
    asm.onFile = (ref, bytes) => got = bytes;
    // Every other chunk of the first sending arrives; then the re-send.
    for (var i = 0; i < first.length; i += 2) {
      asm.feed(XprsPacket.parse(first[i])!);
    }
    for (final w in again) {
      asm.feed(XprsPacket.parse(w)!);
    }
    expect(got, isNotNull, reason: 'every byte arrived, some of them twice');
    expect(got, data);
  });
}
