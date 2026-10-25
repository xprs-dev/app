/*
 * A capability probe made with Bluetooth off is not a verdict.
 *
 * Android answers "no" to every LE capability question while the adapter is
 * not ON, and Ble5Bus.supported() cached whatever it heard first for the life
 * of the process. A phone whose owner switched Bluetooth on a few seconds
 * after the app therefore ran its whole session as a scan-only leaf -- it
 * heard everybody and nobody heard it. Native now answers null in that state;
 * this checks that the Dart side treats null as "ask again" and caches only a
 * real answer (docs/ble5.md section 5).
 */
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reticulum/src/connections/bluetooth/ble5_bus.dart';

const _channel = MethodChannel('com.xprs.app/ble5');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  bool? answer;
  var asked = 0;

  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
      switch (call.method) {
        case 'supported':
          asked++;
          return answer;
        case 'maxPayload':
          return 296;
      }
      return null;
    });
  });

  test('null is asked again; a real answer is cached', () async {
    final logs = <String>[];
    Ble5Bus.instance.onLog = logs.add;

    // Bluetooth off at the probe: not supported for now, and not known.
    answer = null;
    expect(await Ble5Bus.instance.supported(), isFalse);
    expect(Ble5Bus.instance.supportKnown, isFalse);
    expect(await Ble5Bus.instance.supported(), isFalse);
    expect(asked, 2, reason: 'an unknown answer must not be cached');
    expect(logs.where((l) => l.contains('capability unknown')).length, 1,
        reason: 'said once, not once per probe');

    // Bluetooth on: the controller answers, and the answer sticks.
    answer = true;
    expect(await Ble5Bus.instance.supported(), isTrue);
    expect(Ble5Bus.instance.supportKnown, isTrue);
    expect(await Ble5Bus.instance.supported(), isTrue);
    expect(asked, 3, reason: 'a real answer is asked once');
  });
}
