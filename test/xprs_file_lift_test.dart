// A shared file's reference belongs in the envelope: `file:` and `size:` as
// fields, the caption left as words. What the composer appends to the text,
// the core lifts onto the packet (XPRS.md 7.7, 7.7.1).
import 'package:flutter_test/flutter_test.dart';
import 'package:xprs/services/xprs/xprs_file_lift.dart';
import 'package:xprs/services/xprs/xprs_packet.dart';

const _sha = 'qiO966OKkb1p7wTVyGn13orREOc_FJooEGzQleUUDRU';

void main() {
  setUp(() {
    XprsFileLift.meta = (sha) =>
        sha == _sha ? (size: 23800, name: 'antenna.jpg') : null;
  });
  tearDown(() => XprsFileLift.meta = null);

  XprsPacket pkt(String w) => XprsPacket.parse(w)!;

  test('the token leaves the caption and becomes fields', () {
    final p = xprsLiftFileOnPacket(pkt(
        't:message f:X1ARKL d:X1WATT ts:2026-09-08_10:00:00 '
        'm:the antenna file:$_sha.jpg'));
    expect(p['file'], '$_sha.jpg');
    expect(p['size'], '23800');
    expect(p['name'], 'antenna.jpg');
    expect(p['m'], 'the antenna', reason: 'the caption is left as words');
    expect(p.fits, isTrue);
  });

  test('m: stays last, so the caption is not read as fields', () {
    final p = xprsLiftFileOnPacket(pkt(
        't:message f:X1ARKL d:X1WATT ts:2026-09-08_10:00:00 m:x file:$_sha.jpg'));
    expect(p.encode().indexOf(' m:') > p.encode().indexOf(' file:'), isTrue);
  });

  test('a legacy sz: hint is dropped — size: replaces it', () {
    final p = xprsLiftFileOnPacket(pkt(
        't:message f:X1A d:X1B ts:2026-09-08_10:00:00 '
        'm:look file:$_sha.jpg sz:23800'));
    expect(p['m'], 'look');
    expect(p['size'], '23800');
    expect(p.encode().contains('sz:'), isFalse);
  });

  test('a caption of nothing but a file leaves no empty m:', () {
    final p = xprsLiftFileOnPacket(
        pkt('t:message f:X1A d:X1B ts:2026-09-08_10:00:00 m:file:$_sha.jpg'));
    expect(p.has('m'), isFalse);
    expect(p['file'], '$_sha.jpg');
  });

  test('a second file stays in the caption — one file per message', () {
    const other = 'TNC46LbxpKOR6QzVsYaZ019bKxKKp_kmRk143eNQ4Ww';
    final p = xprsLiftFileOnPacket(pkt(
        't:message f:X1A d:X1B ts:2026-09-08_10:00:00 '
        'm:two file:$_sha.jpg file:$other.png'));
    expect(p['file'], '$_sha.jpg');
    expect(p['m'], contains('file:$other.png'));
  });

  test('an unknown file still lifts, with no size to state', () {
    XprsFileLift.meta = (_) => null;
    final p = xprsLiftFileOnPacket(pkt(
        't:message f:X1A d:X1B ts:2026-09-08_10:00:00 m:x file:$_sha.jpg'));
    expect(p['file'], '$_sha.jpg');
    expect(p.has('size'), isFalse);
  });

  test('name: is dropped before size: when the packet would not fit', () {
    XprsFileLift.meta = (_) =>
        (size: 23800, name: 'a-very-long-filename-that-eats-the-budget.jpeg');
    // A caption long enough that name: cannot fit but size: can.
    final caption = 'x' * 120;
    final p = xprsLiftFileOnPacket(pkt(
        't:message f:X1ARKL d:X1WATT ts:2026-09-08_10:00:00 '
        'm:$caption file:$_sha.jpg'));
    expect(p['size'], '23800', reason: 'the size is what a receiver decides with');
    expect(p.has('name'), isFalse);
    expect(p.fits, isTrue);
  });

  test('a name with a space is not a name (7.7.1 / the value rule)', () {
    expect(xprsFileName('holiday photo.jpg'), isNull);
    expect(xprsFileName('holiday.jpg'), 'holiday.jpg');
    expect(xprsFileName('x' * 65), isNull);
  });

  test('nothing to lift, nothing changes', () {
    final w = 't:message f:X1A d:X1B ts:2026-09-08_10:00:00 m:just words';
    expect(xprsLiftFileOnPacket(pkt(w)).encode(), w);
    // Nor on a packet that already states its file.
    final already = 't:message f:X1A d:X1B ts:2026-09-08_10:00:00 '
        'file:$_sha.jpg size:1 m:done';
    expect(xprsLiftFileOnPacket(pkt(already)).encode(), already);
    // Nor on anything that is not a message.
    final other = 't:status f:X1A ts:2026-09-08_10:00:00 m:file:$_sha.jpg';
    expect(xprsLiftFileOnPacket(pkt(other)).encode(), other);
  });
}
