/*
 * The packet-lane file transfer (XPRS.md §7.7.6): a small binary chunked across
 * ordinary 250-byte t:file packets by byte offset, for a transport that passes
 * text but blocks the bulk lane. Split → reassemble → verify against the
 * whole-file hash, in order and shuffled, and the safety walls (poisoned chunk,
 * oversize).
 */
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xprs/services/xprs/xprs_inline_file.dart';
import 'package:xprs/services/xprs/xprs_packet.dart';

void main() {
  Uint8List blob(int n, int seed) {
    final r = Random(seed);
    return Uint8List.fromList([for (var i = 0; i < n; i++) r.nextInt(256)]);
  }

  test('a ~5 kB file round-trips over the packet lane, in order', () {
    final data = blob(5000, 1);
    final wires = xprsInlineSplit(data, from: 'X1WATT', to: 'X1ARKL', ext: 'png',
        nowSec: 1700000000);
    expect(wires.length, greaterThan(9),
        reason: 'well past the 896 B / 9-part inline cap');
    for (final w in wires) {
      expect(XprsPacket.parse(w)!.fits, isTrue, reason: 'each chunk is a packet');
    }
    final asm = XprsInlineAsm();
    (String, Uint8List)? done;
    for (final w in wires) {
      done ??= asm.offer(XprsPacket.parse(w)!);
    }
    expect(done, isNotNull);
    expect(done!.$2, data, reason: 'byte-identical after reassembly + verify');
    expect(done.$1, endsWith('.png'));
  });

  test('chunks arriving shuffled still reassemble', () {
    final data = blob(4096, 2);
    final wires = xprsInlineSplit(data, from: 'X1A', ext: 'jpg', nowSec: 1700000000)
      ..shuffle(Random(9));
    final asm = XprsInlineAsm();
    (String, Uint8List)? done;
    for (final w in wires) {
      done ??= asm.offer(XprsPacket.parse(w)!);
    }
    expect(done!.$2, data);
  });

  test('a poisoned chunk yields no file (whole-file hash is the integrity)', () {
    final data = blob(3000, 3);
    final wires = xprsInlineSplit(data, from: 'X1A', ext: 'png', nowSec: 1700000000);
    // Corrupt one chunk's b: (flip a base64 char) — assembly completes but the
    // sha will not match, so nothing is returned.
    final i = wires.length ~/ 2;
    final p = XprsPacket.parse(wires[i])!;
    final bad = (p['b']![0] == 'A' ? 'B' : 'A') + p['b']!.substring(1);
    wires[i] = wires[i].replaceFirst('b:${p['b']}', 'b:$bad');
    final asm = XprsInlineAsm();
    (String, Uint8List)? done;
    for (final w in wires) {
      done ??= asm.offer(XprsPacket.parse(w)!);
    }
    expect(done, isNull, reason: 'a bad chunk never produces a bad file');
  });

  test('a file over the cap does not use this lane', () {
    expect(xprsInlineSplit(blob(kInlineMaxBytes + 1, 4), from: 'X1A', ext: 'bin'),
        isEmpty);
  });

  test('a repeated chunk is ignored, not double-counted', () {
    final data = blob(2000, 5);
    final wires = xprsInlineSplit(data, from: 'X1A', ext: 'png', nowSec: 1700000000);
    final asm = XprsInlineAsm();
    (String, Uint8List)? done;
    // Feed the first chunk twice, then the rest.
    asm.offer(XprsPacket.parse(wires.first)!);
    for (final w in wires) {
      done ??= asm.offer(XprsPacket.parse(w)!);
    }
    expect(done!.$2, data);
  });
}
