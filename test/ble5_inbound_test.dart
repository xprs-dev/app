/*
 * The BLE5 inbound demux, which had no test at all.
 *
 * The bug this file exists for: `Ble5Bus.stopScan()` used to cancel the
 * EventChannel subscription. Cancelling fires `onCancel` natively, which nulls
 * the sink every scan result is written to — so adverts kept arriving, kept
 * being counted, and were dropped one line later. Nothing re-armed it, and
 * nothing logged it, so a phone went deaf for a whole session after a single
 * GATT link and the only symptom was "messages never arrive".
 */
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reticulum/src/connections/bluetooth/ble5_bus.dart';

const _method = MethodChannel('com.xprs.app/ble5');
const _scanChannel = 'com.xprs.app/ble5_scan';

/// Drives the scan EventChannel the way the native side does, and records
/// whether anyone is listening — the thing that actually broke.
class _FakeNative {
  final List<String> calls = [];
  bool listening = false;
  bool scanRegistered = false;
  Object? startScanAnswer = true;

  void install() {
    final b = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    b.setMockMethodCallHandler(_method, (call) async {
      calls.add(call.method);
      switch (call.method) {
        case 'startScan':
          scanRegistered = true;
          return startScanAnswer;
        case 'stopScan':
          scanRegistered = false;
          return null;
        case 'supported':
          return true;
        case 'maxPayload':
          return 200;
      }
      return null;
    });
    b.setMockStreamHandler(
      const EventChannel(_scanChannel),
      MockStreamHandler.inline(
        onListen: (args, sink) => listening = true,
        onCancel: (args) => listening = false,
      ),
    );
  }

  /// Deliver one advert, exactly as Ble5.kt's onScanResult does — but only if
  /// somebody is listening, which is the native `events ?: return`.
  void deliver(int subtype, List<int> payload) {
    if (!listening) return; // this IS the dropped-frame path
    final env = const StandardMethodCodec().encodeSuccessEnvelope({
      'addr': 'AA:BB:CC:DD:EE:FF',
      'rssi': -55,
      'subtype': subtype,
      'data': Uint8List.fromList(payload),
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(_scanChannel, env, (_) {});
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Ble5Bus is a singleton and its EventChannel subscription is created once
  // with `_sub ??=`, so the fake native side is installed once too — swapping
  // the mock per test would leave the live subscription bound to a dead handler
  // and prove nothing.
  final native = _FakeNative();
  final got = <Ble5Frame>[];

  setUpAll(() {
    native.install();
    Ble5Bus.instance.onFrame(Ble5Subtype.xprs, got.add);
  });

  setUp(() {
    got.clear();
    native.calls.clear();
    native.startScanAnswer = true;
  });

  test('a frame reaches its subtype handler', () async {
    await Ble5Bus.instance.startScan();
    native.deliver(Ble5Subtype.xprs, 't:observation f:X3WWAJ'.codeUnits);
    await Future<void>.delayed(Duration.zero);

    expect(got, hasLength(1));
    expect(String.fromCharCodes(got.single.data), 't:observation f:X3WWAJ');
    expect(got.single.rssi, -55);
  });

  test('a subtype with no handler is dropped, not thrown', () async {
    await Ble5Bus.instance.startScan();
    native.deliver(0x47, [1, 2, 3]); // presence: declared, never handled
    await Future<void>.delayed(Duration.zero);
    expect(got, isEmpty);
  });

  test('stopScan keeps the native sink alive', () async {
    await Ble5Bus.instance.startScan();
    expect(native.listening, isTrue);

    await Ble5Bus.instance.stopScan();
    // THE REGRESSION. Cancelling here nulled the native sink, and every advert
    // that arrived afterwards was counted and discarded with no log line.
    expect(native.listening, isTrue,
        reason: 'stopScan must not cancel the scan EventChannel subscription');
  });

  test('reception survives a stop/start cycle', () async {
    await Ble5Bus.instance.startScan();
    await Ble5Bus.instance.stopScan();
    await Ble5Bus.instance.startScan();

    native.deliver(Ble5Subtype.xprs, 'after the gatt link'.codeUnits);
    await Future<void>.delayed(Duration.zero);

    expect(got, hasLength(1),
        reason: 'a GATT link must not leave the phone permanently deaf');
  });

  test('a null startScan answer does not latch _scanning', () async {
    // notImplemented answers null. `_scanning = ok ?? true` used to believe it,
    // after which the `if (_scanning) return` guard made every retry a no-op.
    await Ble5Bus.instance.stopScan(); // clear _scanning so startScan reaches native
    native.startScanAnswer = null;
    await Ble5Bus.instance.startScan();
    expect(Ble5Bus.instance.scanning, isFalse);

    native.startScanAnswer = true;
    await Ble5Bus.instance.startScan();
    expect(Ble5Bus.instance.scanning, isTrue,
        reason: 'a refused start must leave a later retry able to succeed');
  });
}
