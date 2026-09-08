// The reference index: what a conversation said about a file, kept by hash so
// the size, the name, and a preview's original survive the packets going by.
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/open.dart';
import 'package:xprs/services/media/media_ref_index.dart';
import 'package:xprs/services/xprs/xprs_packet.dart';

void main() {
  setUpAll(() {
    open.overrideFor(
        OperatingSystem.linux, () => DynamicLibrary.open('libsqlite3.so.0'));
  });

  late Directory tmp;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('mediarefidx');
    MediaRefIndex.instance.init('${tmp.path}/media_refs.sqlite3');
  });
  tearDown(() {
    MediaRefIndex.instance.close();
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  const preview = 'qiO966OKkb1p7wTVyGn13orREOc_FJooEGzQleUUDRU';
  const original = 'TNC46LbxpKOR6QzVsYaZ019bKxKKp_kmRk143eNQ4Ww';

  XprsPacket pkt(String w) => XprsPacket.parse(w)!;

  test('a message carrying a file records its size and name', () {
    final p = pkt('t:message f:X1ARKL d:X1WATT ts:2026-09-08_10:00:00 '
        'file:$preview.jpg size:23800 m:the antenna');
    MediaRefIndex.instance.note(p, msgId: 'aa11bb');
    final info = MediaRefIndex.instance.describe(preview)!;
    expect(info.size, 23800);
    expect(info.ext, 'jpg');
    expect(info.role, 'carried');
    expect(info.msg, 'aa11bb');
    expect(info.from, 'X1ARKL');
  });

  test('a companion t:file r: names the original a preview stands for', () {
    MediaRefIndex.instance.note(
        pkt('t:message f:X1ARKL d:X1WATT ts:2026-09-08_10:00:00 '
            'file:$preview.jpg size:23800 m:x'),
        msgId: 'aa11bb');
    MediaRefIndex.instance.note(
        pkt('t:file f:X1ARKL d:X1WATT ts:2026-09-08_10:00:01 r:aa11bb '
            'file:$original.jpg size:2457600 name:antenna.jpg'),
        msgId: 'ignored-for-a-t:file');
    final orig = MediaRefIndex.instance.originalOf(preview)!;
    expect(orig.sha, original);
    expect(orig.size, 2457600);
    expect(orig.name, 'antenna.jpg');
    expect(orig.role, 'original');
    // A file that carried no preview has no "original".
    expect(MediaRefIndex.instance.originalOf(original), isNull);
  });

  test('size: with a unit is read as bytes', () {
    MediaRefIndex.instance.note(
        pkt('t:message f:X1A d:X1B ts:2026-09-08_10:00:00 '
            'file:$preview.png size:240kB m:x'),
        msgId: 'c1');
    expect(MediaRefIndex.instance.describe(preview)!.size, 240000);
  });

  test('a hex query finds a base64url-stored row', () {
    final p = pkt('t:message f:X1A d:X1B ts:2026-09-08_10:00:00 '
        'file:$preview.png size:10 m:x');
    MediaRefIndex.instance.note(p, msgId: 'c2');
    final hex = MediaRefIndex.instance.describe(preview)!;
    final hexQuery = MediaRefIndex.instance.describe(
        _b64uToHex(preview));
    expect(hexQuery?.sha, hex.sha);
  });

  test('a packet with no file: records nothing; a chunk records nothing', () {
    MediaRefIndex.instance
        .note(pkt('t:message f:X1A d:X1B ts:2026-09-08_10:00:00 m:hi'), msgId: 'c3');
    expect(MediaRefIndex.instance.describe(preview), isNull);
    // A 7.7.6 chunk (file: + off: + b:) is transient, not a description.
    MediaRefIndex.instance.note(
        pkt('t:file f:X1A d:X1B ts:2026-09-08_10:00:00 r:c3 '
            'file:$original.png size:5000 off:0 b:AAAA'),
        msgId: 'c4');
    expect(MediaRefIndex.instance.describe(original), isNull);
  });
}

String _b64uToHex(String b64u) {
  const map = '';
  // Use the library's own converter through a parsed ref would be cleaner, but
  // the index accepts hex directly; derive it here to keep the test honest.
  final pad = (4 - b64u.length % 4) % 4;
  final bytes = _decode(b64u + ('=' * pad));
  final sb = StringBuffer();
  for (final b in bytes) {
    sb.write(b.toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}

List<int> _decode(String s) {
  // base64url
  return Uri.parse('data:application/octet-stream;base64,'
          '${s.replaceAll('-', '+').replaceAll('_', '/')}')
      .data!
      .contentAsBytes();
}
