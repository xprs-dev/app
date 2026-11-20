// A platform with no native BLE5 side (the Linux and Windows builds: the bus
// is Android's Ble5.kt) never registers the scan. Listening on the event
// channel used to throw a MissingPluginException that Flutter printed with a
// stack trace on every desktop start. A widget test has no plugins
// registered, which is exactly that platform.
import 'package:flutter_test/flutter_test.dart';
import 'package:reticulum_ble/reticulum_ble.dart';

void main() {
  testWidgets('startScan on a platform with no BLE5 side reports nothing',
      (tester) async {
    await tester.runAsync(() async {
      await Ble5Bus.instance.startScan();
      // Give the event channel a turn to fail, as it did.
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    expect(tester.takeException(), isNull);
    expect(Ble5Bus.instance.wantScan, isFalse);
    expect(Ble5Bus.instance.scanning, isFalse);
    expect(await tester.runAsync(Ble5Bus.instance.supported), isFalse);
  });
}
