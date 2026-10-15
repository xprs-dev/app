// A picture in a status (XPRS.md 7.7.7, section 27): the reference is a field
// beside the words with the size a receiver decides with, a picture too big for
// the packet lane travels as its preview, and a picture with no words is a
// packet with no `m:` at all. The same lift a message gets (xprs_file_lift).
import 'package:flutter_test/flutter_test.dart';
import 'package:xprs/services/xprs/xprs_file_lift.dart';
import 'package:xprs/services/xprs/xprs_packet.dart';
import 'package:xprs/services/xprs/xprs_publisher.dart';

const _orig = 'A6CIaMWn2YqtvxOsXv_PyxY_d7M3IJaYgeBjW5pmS-w';
const _prev = 'nYxKzGm4vT2pQ8dW5jR7cL0aFbNs9hUe3oXiC6EkM1w';

void main() {
  setUp(() {
    XprsFileLift.meta = (sha) => switch (sha) {
          _orig => (size: 724396, name: 'photo.jpg'),
          _prev => (size: 19901, name: null),
          _ => null,
        };
    XprsFileLift.preview = (sha) => sha == _orig ? '$_prev.jpg' : null;
  });
  tearDown(() {
    XprsFileLift.meta = null;
    XprsFileLift.preview = null;
  });

  XprsPacket one(List<String> w) {
    expect(w, hasLength(1));
    return XprsPacket.parse(w.single)!;
  }

  test('a large photo travels as its preview, a field with its size', () {
    final p = one(XprsPublisher.instance
        .debugStatusWires('X16JK8', 'the antenna file:$_orig.jpg'));
    expect(p.type, 'status');
    expect(p['file'], '$_prev.jpg', reason: 'the preview, not the original');
    expect(p['size'], '19901');
    expect(p['m'], 'the antenna', reason: 'the words, without the token');
    expect(p.encode().indexOf('file:'), lessThan(p.encode().indexOf(' m:')),
        reason: 'a field before m:, never caption text');
  });

  test('a small picture travels as itself', () {
    XprsFileLift.preview = (_) => null;
    final p = one(XprsPublisher.instance
        .debugStatusWires('X16JK8', 'tiny file:$_prev.jpg'));
    expect(p['file'], '$_prev.jpg');
    expect(p['size'], '19901');
  });

  test('a picture with no words has no m: at all', () {
    final p = one(
        XprsPublisher.instance.debugStatusWires('X16JK8', 'file:$_orig.jpg'));
    expect(p['file'], '$_prev.jpg');
    expect(p.has('m'), isFalse);
  });

  test('words alone are unchanged', () {
    final p = one(
        XprsPublisher.instance.debugStatusWires('X16JK8', 'good morning'));
    expect(p.has('file'), isFalse);
    expect(p['m'], 'good morning');
  });

  test('a correction names its original, and a reply stays a reply (7.8.1)', () {
    final edited = one(XprsPublisher.instance
        .debugStatusWires('X16JK8', 'meet at seven', editOf: '3F8923'));
    expect(edited.type, 'status');
    expect(edited['edit'], '3f8923', reason: 'identifiers are lower case');
    expect(edited['m'], 'meet at seven');
    expect(edited.fits, isTrue);
    final plain = one(XprsPublisher.instance
        .debugStatusWires('X16JK8', 'meet at seven', editOf: 'not-an-id'));
    expect(plain.has('edit'), isFalse, reason: 'a bad identifier is not sent');
  });
}
