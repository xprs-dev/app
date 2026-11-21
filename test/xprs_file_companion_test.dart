// The description of the file behind a preview (`t:file r:<message>`, spec
// 7.7.1, 7.7.7) names its piece list with `ph:` when it has one, which is
// what lets a reader take pieces from several holders (7.7.2).
import 'package:flutter_test/flutter_test.dart';
import 'package:xprs/services/xprs/xprs_file_lift.dart';
import 'package:xprs/services/xprs/xprs_packet.dart';
import 'package:xprs/services/xprs/xprs_publisher.dart';
import 'package:xprs/services/xprs/xprs_send.dart';

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

const _file = 'nYxKzGm4vT2pQ8dW5jR7cL0aFbNs9hUe3oXiC6EkM1w.jpg';
const _list = 'qA7dTf2mWx9bK4pZcV0yLuJ3gRhN8sE5iDoQ6vXaB1M.xpl';

void main() {
  late _Recorder air;
  setUp(() {
    air = _Recorder();
    XprsPublisher.instance.bearers = [air];
  });
  tearDown(() => XprsSend.pieceListRef = null);

  Future<XprsPacket> companion(XprsFileLift lift) async {
    XprsSend.airFileCompanion('X1QZ3N', 'X1RD89', 'abc123', lift);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    return XprsPacket.parse(air.sent.firstWhere((w) => w.startsWith('t:file')))!;
  }

  test('a file with a piece list is described with ph:', () async {
    XprsSend.pieceListRef = (ref) async => ref == _file ? _list : null;
    final p = await companion(const XprsFileLift(
        text: '',
        original: _file,
        originalSize: 3145728,
        originalName: 'dipole.jpg'));
    expect(p['file'], _file);
    expect(p['ph'], _list);
    expect(p['r'], 'abc123');
    expect(p['name'], 'dipole.jpg');
    expect(p.fits, isTrue);
  });

  test('a file of one piece has no ph:', () async {
    XprsSend.pieceListRef = (ref) async => null;
    final p = await companion(
        const XprsFileLift(text: '', original: _file, originalSize: 5000));
    expect(p.has('ph'), isFalse);
    expect(p['size'], '5000');
  });

  test('a station that cannot say still describes the file', () async {
    XprsSend.pieceListRef = (ref) async => throw StateError('no archive');
    final p = await companion(
        const XprsFileLift(text: '', original: _file, originalSize: 3145728));
    expect(p['file'], _file);
    expect(p.has('ph'), isFalse);
  });
}
