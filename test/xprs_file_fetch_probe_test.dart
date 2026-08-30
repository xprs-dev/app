// A `cmd:file` ask to a station that never answers must not hold the caller
// for the transfer's hour. Measured on the C61: the updater asked the ESP32 for
// a release it could not hold and sat at 0% for as long as anyone watched.
import 'package:flutter_test/flutter_test.dart';
import 'package:xprs/services/xprs/xprs_files.dart';
import 'package:xprs/services/xprs/xprs_id.dart';
import 'package:xprs/services/xprs/xprs_packet.dart';
import 'package:xprs/services/xprs/xprs_publisher.dart';

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
      {required int part, String slot = 'status', Duration? ttl}) async {
    sent.add(wire);
    return XprsSendResult.sent;
  }
}

const _sha =
    '72088e1a542fda167831a58b2c2b07aba76d246a4673536f1ebdeba78707173a';

void main() {
  late _Recorder air;
  setUp(() {
    air = _Recorder();
    XprsPublisher.instance.bearers = [air];
  });

  String askId() {
    final ask = air.sent.firstWhere((w) => w.contains('cmd:file'));
    return xprsIdentifier(XprsPacket.parse(ask)!);
  }

  XprsPacket result(String id, int code) => XprsPacket.parse(
      't:result f:X3GSLC d:X1SELF ts:2026-08-30_08:00:00 r:$id code:$code')!;

  test('unanswered within acceptWithin gives up, long before the timeout',
      () async {
    final sw = Stopwatch()..start();
    final path = await XprsFileFetch.instance.fetch(
      archiver: 'X3GSLC',
      shaHex: _sha,
      selfCallsign: 'X1SELF',
      ext: 'apk',
      timeout: const Duration(seconds: 30),
      acceptWithin: const Duration(milliseconds: 200),
    );
    expect(path, isNull);
    expect(sw.elapsedMilliseconds, lessThan(2000),
        reason: 'the ask was unanswered; that is known in 200 ms, not 30 s');
  });

  test('a 202 in hand hands over to the transfer timeout', () async {
    final fut = XprsFileFetch.instance.fetch(
      archiver: 'X3GSLC',
      shaHex: _sha,
      selfCallsign: 'X1SELF',
      ext: 'apk',
      timeout: const Duration(seconds: 30),
      acceptWithin: const Duration(milliseconds: 200),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));
    XprsFileFetch.instance.onResult(result(askId(), 202));
    var done = false;
    // ignore: unawaited_futures
    fut.whenComplete(() => done = true);
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(done, isFalse, reason: 'accepted — the bytes are coming');
    // The holder then refuses after all: that still ends the wait.
    XprsFileFetch.instance.onResult(result(askId(), 404));
    expect(await fut, isNull);
  });
}
