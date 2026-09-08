/*
 * The packet-lane transfer under loss (XPRS.md 7.7.6, 8.1): chunks go out as
 * datagrams with no bookkeeping, some are lost, the receiver waits a moment
 * and says what it holds (a `have:` bitfield, least significant bit first),
 * and the sender re-sends exactly the chunks the map lacks. Repeated until the
 * file verifies as a whole. Everything in-process: a recording bearer that
 * drops chosen chunks, a real assembler driven by a test clock.
 */
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xprs/services/xprs/xprs_inline_file.dart';
import 'package:xprs/services/xprs/xprs_inline_sender.dart';
import 'package:xprs/services/xprs/xprs_packet.dart';
import 'package:xprs/services/xprs/xprs_publisher.dart';

class _LossyBearer implements XprsBearer {
  _LossyBearer(this.dropOffsets);
  final Set<int> dropOffsets;
  final List<String> delivered = [];
  final List<String> everything = [];
  bool datagramSeen = false;
  @override
  String get name => 'reticulum';
  @override
  String get archiveBearer => 'rns';
  @override
  bool get shortRange => false;
  @override
  Future<bool> get active async => true;
  @override
  Future<XprsSendResult> send(String wire,
      {required int part,
      String slot = 'status',
      Duration? ttl,
      bool datagram = false}) async {
    everything.add(wire);
    if (datagram) datagramSeen = true;
    final p = XprsPacket.parse(wire)!;
    final off = int.tryParse(p['off'] ?? '');
    if (off != null && dropOffsets.remove(off)) return XprsSendResult.queued;
    delivered.add(wire);
    return XprsSendResult.queued;
  }
}

Uint8List _blob(int n, int seed) {
  final r = Random(seed);
  return Uint8List.fromList(List.generate(n, (_) => r.nextInt(256)));
}

void main() {
  test('bitfield round-trips: what one side encodes the other decodes', () {
    final held = {0, 96, 288, 480}; // chunk indexes 0,1,3,5 of 8 (len 96)
    final have = xprsInlineHaveEncode(held, 8 * 96 - 10, 96);
    final back = xprsInlineHaveDecode(have, xprsInlineChunkCount(8 * 96 - 10, 96));
    expect(back, {0, 1, 3, 5});
    expect(xprsInlineHaveDecode('full', 8), isNull);
    expect(xprsInlineHaveDecode('4/8', 8), isNull);
  });

  test('lost chunks are reported by the receiver and re-sent, only those',
      () async {
    final bytes = _blob(3000, 5);
    final all = xprsInlineSplit(bytes, from: 'X1SEND', to: 'X1RECV', ext: 'png');
    expect(all.length, greaterThan(20));
    final chunkLen = base64Len(all.first);
    // Drop three chunks on the first pass.
    final drop = {1 * chunkLen, 7 * chunkLen, (all.length - 1) * chunkLen};
    final bearer = _LossyBearer(Set.of(drop));
    XprsPublisher.instance.bearers = [bearer];

    final sender = XprsInlineSender.instance..gap = Duration.zero;
    final asm = XprsInlineAsm(timers: false);
    final reports = <String>[];
    asm.onStalled = (from, ref, have) => reports.add(have);
    Uint8List? got;
    asm.onFile = (ref, b) => got = b;

    // First pass.
    expect(sender.send(bytes, from: 'X1SEND', to: 'X1RECV', ext: 'png'),
        isNotNull);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(bearer.datagramSeen, isTrue, reason: 'chunks are datagrams');
    expect(bearer.delivered.length, all.length - 3);
    var t = DateTime(2026, 9, 8, 12);
    for (final w in bearer.delivered) {
      asm.feed(XprsPacket.parse(w)!, now: t);
      t = t.add(const Duration(milliseconds: 50));
    }
    expect(got, isNull, reason: 'three chunks short');

    // Silence. The receiver says what it holds.
    asm.sweepStalled(t.add(const Duration(seconds: 5)));
    expect(reports, isEmpty, reason: 'not yet — chunks may still be coming');
    asm.sweepStalled(t.add(XprsInlineAsm.idleGap));
    expect(reports.length, 1);

    // The sender answers the map with the missing chunks and nothing else.
    bearer.delivered.clear();
    final n = sender.onHave(bytes,
        from: 'X1SEND', to: 'X1RECV', ext: 'png', have: reports.single);
    expect(n, 3);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(bearer.delivered.length, 3);
    final resentOffs = bearer.delivered
        .map((w) => int.parse(XprsPacket.parse(w)!['off']!))
        .toSet();
    expect(resentOffs, drop);

    for (final w in bearer.delivered) {
      asm.feed(XprsPacket.parse(w)!, now: t);
    }
    expect(got, isNotNull, reason: 'whole and verified');
    expect(got, bytes);

    // A complete map is answered with nothing to send.
    final full = xprsInlineHaveEncode(
        [for (var k = 0; k < all.length; k++) k * chunkLen],
        bytes.length,
        chunkLen);
    expect(
        sender.onHave(bytes,
            from: 'X1SEND', to: 'X1RECV', ext: 'png', have: full),
        0);
  });

  test('reports back off and stop, so a dead sender is not asked forever', () {
    final bytes = _blob(1200, 9);
    final all = xprsInlineSplit(bytes, from: 'X1SEND', to: 'X1RECV', ext: 'bin');
    final asm = XprsInlineAsm(timers: false);
    var reports = 0;
    asm.onStalled = (_, __, ___) => reports++;
    var t = DateTime(2026, 9, 8, 12);
    asm.feed(XprsPacket.parse(all.first)!, now: t); // one chunk, then silence
    for (var i = 0; i < 70; i++) {
      t = t.add(const Duration(seconds: 10));
      asm.sweepStalled(t);
    }
    expect(reports, XprsInlineAsm.maxReports);
    expect(asm.inFlight, isEmpty, reason: 'expired with the hold');
  });
}

/// The raw chunk length a wire carries.
int base64Len(String wire) {
  final b = XprsPacket.parse(wire)!['b']!;
  return (b.length * 3) ~/ 4;
}
