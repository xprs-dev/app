// XBLOB Dart<->C parity and loopback tests, mirroring the firmware's
// common/xprs_blob/test_xblob_host.c scenario for scenario. The golden frame
// bytes pin the wire so a change in either implementation fails loudly here
// or there.
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:xprs/services/mesh/xprs_blob.dart';

class _Q {
  final frames = <Uint8List>[];
  static const cap = 12; // small, to exercise busy/txReady
  int push(Uint8List f) {
    if (frames.length >= cap) return xblobSendBusy;
    frames.add(Uint8List.fromList(f));
    return xblobSendOk;
  }
}

class _End extends XblobDelegate {
  _End(this.q);
  final _Q q;
  Uint8List? src; // server side
  Uint8List? dst; // receiver side
  bool? doneOk;
  @override
  int send(Uint8List frame) => q.push(frame);
  @override
  Uint8List? blockRead(int off, int cap) {
    final s = src!;
    if (off >= s.length) return Uint8List(0);
    return Uint8List.sublistView(s, off, min(off + cap, s.length));
  }

  @override
  bool blockWrite(int off, Uint8List data) {
    dst!.setRange(off, off + data.length, data);
    return true;
  }

  @override
  void done(bool ok) => doneOk = ok;
}

Uint8List _image(int size) {
  final b = Uint8List(size);
  for (var i = 0; i < size; i++) {
    b[i] = ((i * 2654435761) >> 13) & 0xFF;
  }
  return b;
}

/// Run one transfer with a loss/corruption policy. Returns receiver doneOk.
bool? _run({
  required int size,
  int dropEveryBlock = -1,
  int corruptFirst = 0,
  bool dropDone = false,
  int dropHashes = 0,
  int dropReady = 0,
  int blackHoleIdx = -1,
  Uint8List? wrongSha,
  required Uint8List dst,
}) {
  final img = _image(size);
  final sha = Uint8List.fromList(crypto.sha256.convert(img).bytes);
  final s2r = _Q(), r2s = _Q();
  final srvD = _End(s2r)..src = img;
  final rcvD = _End(r2s)..dst = dst;
  var now = 1000;
  final rcv = XblobSession.receiver(rcvD, wrongSha ?? sha, size, now);
  // deliver START by hand: the app looks the image up by sha and starts serving
  expect(xblobStartSha(r2s.frames.removeAt(0)), isNotNull);
  final srv = XblobSession.server(srvD, sha, size);

  var delivered = 0, corrupt = corruptFirst, dDone = dropDone;
  var dHashes = dropHashes, dReady = dropReady;
  var guard = 0;
  while (rcvD.doneOk == null && guard++ < 400000) {
    var moved = false;
    if (s2r.frames.isNotEmpty) {
      moved = true;
      final f = s2r.frames.removeAt(0);
      srv.txReady();
      var drop = false;
      if (f[1] == xblobTBlock) {
        final idx = f[2] | (f[3] << 8);
        delivered++;
        if (idx == blackHoleIdx) drop = true;
        if (dropEveryBlock > 0 && delivered % dropEveryBlock == 0) drop = true;
        if (!drop && corrupt > 0) {
          corrupt--;
          f[4] ^= 0xFF;
        }
      }
      if (f[1] == xblobTHashes && dHashes > 0) {
        dHashes--;
        drop = true;
      }
      if (f[1] == xblobTDone && dDone) {
        dDone = false;
        drop = true;
      }
      if (!drop) rcv.rx(f, now);
    }
    if (r2s.frames.isNotEmpty) {
      moved = true;
      final f = r2s.frames.removeAt(0);
      var drop = false;
      if (f[1] == xblobTReady && dReady > 0) {
        dReady--;
        drop = true;
      }
      if (!drop) srv.rx(f, now);
      srv.txReady();
    }
    if (!moved) {
      now += kXblobStallMs + 10;
      rcv.tick(now);
      srv.txReady();
      if (s2r.frames.isEmpty && r2s.frames.isEmpty && rcvD.doneOk == null) {
        if (rcv.dead) break;
      }
    }
  }
  return rcvD.doneOk;
}

void main() {
  test('golden frames match the C wire', () {
    // START: 42 0A + sha32
    final sha = Uint8List.fromList(List.generate(32, (i) => i));
    final q = _Q();
    XblobSession.receiver(_End(q), sha, 1000, 0);
    final start = q.frames.first;
    expect(start[0], 0x42);
    expect(start[1], 0x0A);
    expect(start.sublist(2), sha);

    // MANIFEST from a 500-byte image: 42 01 ver sha32 size32 blksz16 nb16 hl sl
    final q2 = _Q();
    final img = _image(500);
    final isha = Uint8List.fromList(crypto.sha256.convert(img).bytes);
    XblobSession.server(_End(q2)..src = img, isha, 500, sig85: 'SIGSIG');
    final man = q2.frames.first;
    expect(man[0], 0x42);
    expect(man[1], 0x01);
    expect(man[2], 1); // version
    expect(man.sublist(3, 35), isha);
    expect(man[35] | (man[36] << 8), 500); // size lo16
    expect(man[39] | (man[40] << 8), 240); // blksz
    expect(man[41] | (man[42] << 8), 3); // nblocks = ceil(500/240)
    expect(man[43], 4); // hashlen
    expect(man[44], 6); // siglen
    expect(String.fromCharCodes(man.sublist(45, 51)), 'SIGSIG');

    // No BLOCK before READY (the sync barrier)...
    expect(q2.frames.any((f) => f[1] == xblobTBlock), isFalse);
    // ...and BLOCK 0 carries the first 240 raw bytes once READY crosses.
    final srv2 = q2; // keep reading the same queue
    // reconstruct: the server instance is out of scope; simplest is a fresh pair
    final q3 = _Q();
    final srv = XblobSession.server(_End(q3)..src = img, isha, 500);
    srv.rx(Uint8List.fromList([kXblobMagic, xblobTReady]), 0);
    expect(srv2.frames.isNotEmpty || q3.frames.isNotEmpty, isTrue);
    final blk = q3.frames.firstWhere((f) => f[1] == xblobTBlock);
    expect(blk[2] | (blk[3] << 8), 0);
    expect(blk.sublist(4), img.sublist(0, 240));
    final hashes = q3.frames.firstWhere((f) => f[1] == xblobTHashes);
    expect(hashes.sublist(5, 9),
        crypto.sha256.convert(img.sublist(0, 240)).bytes.sublist(0, 4));
  });

  test('clean 162 KB', () {
    final dst = Uint8List(162000);
    expect(_run(size: 162000, dst: dst), isTrue);
    expect(dst, _image(162000));
  });

  test('drop 1/17 blocks -> NEED recovers', () {
    final dst = Uint8List(60000);
    expect(_run(size: 60000, dropEveryBlock: 17, dst: dst), isTrue);
    expect(dst, _image(60000));
  });

  test('corrupt 40 blocks -> hash gate + NEED recovers', () {
    final dst = Uint8List(60000);
    expect(_run(size: 60000, corruptFirst: 40, dst: dst), isTrue);
    expect(dst, _image(60000));
  });

  test('dropped DONE -> stall timer asks anyway', () {
    final dst = Uint8List(50000);
    expect(_run(size: 50000, dropDone: true, dst: dst), isTrue);
  });

  test('lost HASHES -> START restart', () {
    final dst = Uint8List(60000);
    expect(_run(size: 60000, dropHashes: 1, dst: dst), isTrue);
    expect(dst, _image(60000));
  });

  test('lost READY -> re-READY', () {
    final dst = Uint8List(30000);
    expect(_run(size: 30000, dropReady: 1, dst: dst), isTrue);
  });

  test('black-holed block -> bounded give-up', () {
    final dst = Uint8List(20000);
    expect(_run(size: 20000, blackHoleIdx: 5, dst: dst), isFalse);
  });

  test('wrong-sha manifest rejected', () {
    final img = _image(8000);
    final real = Uint8List.fromList(crypto.sha256.convert(img).bytes);
    final fake = Uint8List.fromList(real)..[0] ^= 0xFF;
    final dst = Uint8List(8000);
    expect(_run(size: 8000, wrongSha: fake, dst: dst), isFalse);
  });
}
